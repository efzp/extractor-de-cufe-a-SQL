"""Inferencia acotada desde Blob y Azure SQL para un job sin estado.

Cada registro se confirma por separado mediante el procedimiento SQL. Si el
proceso falla, una ejecucion posterior retoma las facturas sin prediccion.
"""

from __future__ import annotations

import struct
import tempfile
from pathlib import Path

from ml_dataset.service import query_frame
from ml_inferencia.publicacion import _registrar, consultar_facturas_ids, hash_variables
from ml_inferencia.service import (
    calcular_top3,
    cargar_manifiesto,
    comprobar_entorno_modelo,
    preparar_inferencia,
)
from scripts.probar_inferencia_blob_azure_sql import descargar_paquete
from scripts.probar_modelo_linux import extraer_modelo_seguro, sha256_archivo


PENDIENTES_SQL = """
SELECT TOP (?) v.*
FROM [ml].[vw_FacturaOrigenMlV1] AS v
JOIN [dian].[XmlExtraccion] AS e
  ON e.[DocumentoXmlID] = v.[DocumentoXmlID]
 AND e.[VersionExtractor] = v.[VersionExtractor]
JOIN [ml].[DatasetVersion] AS d
  ON d.[DatasetVersionID] = ?
 AND d.[ClienteID] = v.[ClienteID]
WHERE v.[ClienteID] = ?
  AND v.[VersionExtractor] = 1
  -- DatasetFila contiene solo matches aceptados; el snapshot leyó todas
  -- las facturas anteriores a la publicación del dataset.
  AND e.[FechaExtraccionUTC] > d.[FechaCreacionUTC]
  AND NOT EXISTS
  (
      SELECT 1 FROM [ml].[DatasetFila] AS f
      WHERE f.[DatasetVersionID] = ?
        AND f.[DocumentoXmlID] = v.[DocumentoXmlID]
  )
  AND NOT EXISTS
  (
      SELECT 1 FROM [ml].[PrediccionPlantilla] AS p
      WHERE p.[DocumentoXmlID] = v.[DocumentoXmlID]
        AND p.[ModeloArtefactoSha256] = ?
  )
ORDER BY v.[DocumentoXmlID] DESC;
"""


def conectar_sql(credencial, servidor: str, base: str, driver: str):
    """Abre SQL con el mismo token Entra usado por la identidad del job."""
    import pyodbc

    token = credencial.get_token("https://database.windows.net/.default").token
    token_bytes = token.encode("utf-16-le")
    token_odbc = struct.pack("=i", len(token_bytes)) + token_bytes
    cadena = (
        f"DRIVER={{{driver}}};SERVER=tcp:{servidor},1433;DATABASE={base};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
    )
    return pyodbc.connect(cadena, attrs_before={1256: token_odbc}, autocommit=True)


def seleccionar_facturas(connection, *, cliente_id: int, dataset_version_id: int,
                        hash_modelo: str, limite: int, xml_ids: list[int] | None):
    if xml_ids is not None:
        return consultar_facturas_ids(connection, cliente_id, dataset_version_id, xml_ids)
    facturas = query_frame(
        connection, PENDIENTES_SQL,
        (limite, dataset_version_id, cliente_id, dataset_version_id, hash_modelo),
    )
    if not facturas.empty:
        if facturas["DocumentoXmlID"].isna().any() or facturas["DocumentoXmlID"].duplicated().any():
            raise ValueError("La seleccion devolvio DocumentoXmlID nulos o repetidos.")
        if facturas["cufe"].isna().any() or facturas["cufe"].duplicated().any():
            raise ValueError("La seleccion devolvio CUFE nulos o repetidos.")
    return facturas


def inferir_y_publicar(connection, *, carpeta_modelo: Path, facturas,
                      cliente_id: int, dataset_version_id: int,
                      nombre_modelo: str, hash_modelo: str,
                      hash_manifiesto: str, publicar: bool) -> dict:
    if facturas.empty:
        return {"resultado": "SIN_PENDIENTES", "facturas": 0,
                "publicadas": 0, "existentes": 0, "documento_xml_ids": []}

    variables = preparar_inferencia(facturas)
    from autogluon.tabular import TabularPredictor

    predictor = TabularPredictor.load(str(carpeta_modelo / "modelo"))
    predicciones = calcular_top3(facturas, variables, predictor)
    ids = facturas["DocumentoXmlID"].astype(int).tolist()
    if predicciones["documento_xml_id"].astype(int).tolist() != ids:
        raise ValueError("Se altero el orden de DocumentoXmlID durante la inferencia.")
    hashes = [hash_variables(variables.iloc[i]) for i in range(len(variables))]
    if not publicar:
        return {
            "resultado": "SOLO_VALIDACION", "facturas": len(ids),
            "publicadas": 0, "existentes": 0, "documento_xml_ids": ids,
            "top3": [
                {"documento_xml_id": xml_id,
                 "opciones": [
                     {"plantilla": str(predicciones.iloc[i][f"plantilla_top{puesto}"]),
                      "probabilidad": float(predicciones.iloc[i][f"probabilidad_top{puesto}"])}
                     for puesto in (1, 2, 3)]}
                for i, xml_id in enumerate(ids)
            ],
        }

    resultados = []
    cursor = connection.cursor()
    try:
        for i, xml_id in enumerate(ids):
            # La conexion es autocommit y el procedimiento tiene su propia
            # transaccion: una falla no revierte las filas anteriores.
            fila = _registrar(
                cursor, cliente_id=cliente_id, dataset_version_id=dataset_version_id,
                nombre_modelo=nombre_modelo, hash_modelo=hash_modelo,
                hash_manifiesto=hash_manifiesto,
                hash_variables_fila=hashes[i], fila=predicciones.iloc[i],
            )
            if int(fila["DocumentoXmlID"]) != xml_id or fila["Resultado"] not in ("REGISTRADA", "YA_EXISTE"):
                raise RuntimeError(f"Respuesta SQL inesperada para DocumentoXmlID={xml_id}.")
            resultados.append({
                "documento_xml_id": xml_id,
                "prediccion_plantilla_id": int(fila["PrediccionPlantillaID"]),
                "resultado": fila["Resultado"],
                "estado_revision": fila["EstadoRevision"],
            })
    finally:
        cursor.close()
    return {
        "resultado": "PUBLICACION_COMPLETA", "facturas": len(ids),
        "publicadas": sum(f["resultado"] == "REGISTRADA" for f in resultados),
        "existentes": sum(f["resultado"] == "YA_EXISTE" for f in resultados),
        "documento_xml_ids": ids, "filas": resultados,
    }


def ejecutar(*, cuenta: str, contenedor: str, blob: str,
            sha_paquete: str, sha_manifiesto: str,
            servidor: str, base: str, driver: str,
            cliente_id: int, nombre_modelo: str, limite: int,
            xml_ids: list[int] | None, publicar: bool) -> dict:
    if not all((cuenta, contenedor, blob, servidor, base, driver)):
        raise ValueError("Falta configurar Blob o Azure SQL.")
    if cliente_id <= 0 or not nombre_modelo.strip() or len(nombre_modelo.strip()) > 120:
        raise ValueError("ClienteID o NombreModelo no valido.")
    if limite < 1 or limite > 100:
        raise ValueError("El lote debe contener entre 1 y 100 facturas.")
    if xml_ids is not None and (
        not xml_ids or len(xml_ids) > 10 or any(i <= 0 for i in xml_ids)
        or len(set(xml_ids)) != len(xml_ids)
    ):
        raise ValueError("La prueba explicita admite de 1 a 10 DocumentoXmlID positivos y distintos.")
    for valor in (sha_paquete, sha_manifiesto):
        if len(valor) != 64 or any(c not in "0123456789abcdef" for c in valor):
            raise ValueError("Los SHA-256 fijados deben ser hexadecimales en minusculas.")

    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    with DefaultAzureCredential(exclude_interactive_browser_credential=True) as credencial:
        with tempfile.TemporaryDirectory(prefix="dian_ml_job_") as temporal:
            carpeta = Path(temporal)
            paquete = carpeta / "modelo.tar.gz"
            with BlobServiceClient(
                account_url=f"https://{cuenta}.blob.core.windows.net",
                credential=credencial,
            ) as servicio:
                cliente_blob = servicio.get_blob_client(container=contenedor, blob=blob)
                descarga = descargar_paquete(cliente_blob, paquete, sha_paquete)
            extraer_modelo_seguro(paquete, carpeta)
            ruta_manifiesto = carpeta / "manifiesto.json"
            if sha256_archivo(ruta_manifiesto) != sha_manifiesto:
                raise ValueError("El SHA-256 del manifiesto no coincide con el fijado.")
            manifiesto = cargar_manifiesto(carpeta, cliente_id)
            comprobar_entorno_modelo(manifiesto)
            dataset_version_id = int(manifiesto["dataset_version"]["DatasetVersionID"])
            if str(descarga["datasetversion_metadata"]) != str(dataset_version_id):
                raise ValueError("La version del dataset en Blob no coincide con el manifiesto.")

            connection = conectar_sql(credencial, servidor, base, driver)
            try:
                actual = query_frame(connection, "SELECT DB_NAME() AS BaseActual;", ())
                if len(actual) != 1 or actual.iloc[0]["BaseActual"] != base:
                    raise ValueError("La conexion SQL apunta a otra base de datos.")
                facturas = seleccionar_facturas(
                    connection, cliente_id=cliente_id,
                    dataset_version_id=dataset_version_id,
                    hash_modelo=sha_paquete, limite=limite, xml_ids=xml_ids,
                )
                resultado = inferir_y_publicar(
                    connection, carpeta_modelo=carpeta, facturas=facturas,
                    cliente_id=cliente_id, dataset_version_id=dataset_version_id,
                    nombre_modelo=nombre_modelo.strip(), hash_modelo=sha_paquete,
                    hash_manifiesto=sha_manifiesto, publicar=publicar,
                )
            finally:
                connection.close()
    return {
        "cliente_id": cliente_id,
        "dataset_version_id": dataset_version_id,
        "modelo_artefacto_sha256": sha_paquete,
        "manifiesto_sha256": sha_manifiesto,
        "blob_etag": descarga["etag"],
        **resultado,
    }
