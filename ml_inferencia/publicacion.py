"""Prueba acotada de publicacion de inferencias en Azure SQL."""

from __future__ import annotations

import hashlib
import json
import math
from decimal import Decimal
from pathlib import Path

from ml_dataset.service import query_frame
from ml_inferencia.service import (
    calcular_top3,
    cargar_manifiesto,
    comprobar_entorno_modelo,
    preparar_inferencia,
)
from scripts.entrenar_modelo_azure_sql import BOOLEANAS, NUMERICAS, PREDICTORAS, conectar_sql


EXEC_REGISTRAR = """
EXEC [ml].[sp_RegistrarPrediccionPlantilla]
    @ClienteID = ?, @DocumentoXmlID = ?, @VersionExtractor = ?,
    @DatasetVersionID = ?, @NombreModelo = ?,
    @ModeloArtefactoSha256 = ?, @ManifiestoSha256 = ?, @HashVariablesSha256 = ?,
    @PlantillaTop1 = ?, @ProbabilidadTop1 = ?,
    @PlantillaTop2 = ?, @ProbabilidadTop2 = ?,
    @PlantillaTop3 = ?, @ProbabilidadTop3 = ?;
"""

DESTINO_SQL = """
SELECT DB_NAME() AS [BaseActual],
       OBJECT_ID(N'ml.PrediccionPlantilla', N'U') AS [TablaID],
       OBJECT_ID(N'ml.sp_RegistrarPrediccionPlantilla', N'P') AS [ProcedimientoID];
"""


def sha256_archivo(ruta: Path) -> str:
    if not ruta.is_file():
        raise ValueError(f"No existe el paquete local del modelo: {ruta}")
    digest = hashlib.sha256()
    with ruta.open("rb") as archivo:
        for bloque in iter(lambda: archivo.read(1024 * 1024), b""):
            digest.update(bloque)
    return digest.hexdigest()


def consultar_facturas_ids(connection, cliente_id: int, dataset_version_id: int,
                          documento_xml_ids: list[int]):
    if not documento_xml_ids or len(documento_xml_ids) > 100:
        raise ValueError("Se requieren de 1 a 100 DocumentoXmlID.")
    if any(xml_id <= 0 for xml_id in documento_xml_ids) or len(set(documento_xml_ids)) != len(documento_xml_ids):
        raise ValueError("DocumentoXmlID debe ser positivo y no repetido.")
    placeholders = ", ".join("?" for _ in documento_xml_ids)
    sql = f"""
SELECT v.*
FROM [ml].[vw_FacturaOrigenMlV1] AS v
JOIN [dian].[XmlExtraccion] AS e
  ON e.[DocumentoXmlID] = v.[DocumentoXmlID]
 AND e.[VersionExtractor] = v.[VersionExtractor]
JOIN [ml].[DatasetVersion] AS d
  ON d.[DatasetVersionID] = ?
 AND d.[ClienteID] = v.[ClienteID]
WHERE v.[ClienteID] = ?
  AND v.[DocumentoXmlID] IN ({placeholders})
  AND e.[FechaExtraccionUTC] > d.[FechaCreacionUTC]
  AND NOT EXISTS
  (
      SELECT 1 FROM [ml].[DatasetFila] AS f
      WHERE f.[DatasetVersionID] = ?
        AND f.[DocumentoXmlID] = v.[DocumentoXmlID]
  )
ORDER BY v.[DocumentoXmlID];
"""
    facturas = query_frame(
        connection, sql, (dataset_version_id, cliente_id, *documento_xml_ids, dataset_version_id)
    )
    encontrados = facturas["DocumentoXmlID"].astype(int).tolist()
    if len(encontrados) != len(documento_xml_ids) or set(encontrados) != set(documento_xml_ids):
        faltantes = sorted(set(documento_xml_ids) - set(encontrados))
        raise ValueError(f"XML no elegibles o ausentes en la vista ML: {faltantes}")
    if facturas["cufe"].isna().any() or facturas["cufe"].duplicated().any():
        raise ValueError("La consulta devolvio CUFE nulos o repetidos.")
    return facturas


def hash_variables(fila) -> str:
    """SHA-256 de JSON UTF-8 v1, con columnas en el orden exacto del modelo.

    Nulos -> null; numericos -> float JSON; categoricos/texto -> cadena.
    No incluye DocumentoXmlID: dos XML con iguales variables comparten hash.
    """
    import pandas as pd

    valores = []
    for columna in PREDICTORAS:
        valor = fila[columna]
        if pd.isna(valor):
            valores.append(None)
        elif columna in (*NUMERICAS, *BOOLEANAS):
            numero = float(valor)
            if not math.isfinite(numero):
                raise ValueError(f"Variable numerica no finita: {columna}")
            valores.append(numero)
        else:
            valores.append(str(valor))
    canonico = json.dumps(
        {"contrato": "ml_variables_v1", "columnas": list(PREDICTORAS), "valores": valores},
        ensure_ascii=False, allow_nan=False, separators=(",", ":"),
    )
    return hashlib.sha256(canonico.encode("utf-8")).hexdigest()


def _probabilidad(valor) -> Decimal:
    numero = Decimal(str(float(valor))).quantize(Decimal("0.000000000001"))
    if not numero.is_finite() or not Decimal(0) <= numero <= Decimal(1):
        raise ValueError("Probabilidad del modelo no valida.")
    return numero


def _registrar(cursor, *, cliente_id: int, dataset_version_id: int,
              nombre_modelo: str, hash_modelo: str, hash_manifiesto: str,
              hash_variables_fila: str, fila) -> dict:
    probabilidades = [_probabilidad(fila[f"probabilidad_top{i}"]) for i in (1, 2, 3)]
    plantillas = [str(fila[f"plantilla_top{i}"]) for i in (1, 2, 3)]
    if len(set(plantillas)) != 3 or any(not p.strip() for p in plantillas):
        raise ValueError("El modelo no entrego tres plantillas distintas.")
    if probabilidades != sorted(probabilidades, reverse=True):
        raise ValueError("El top 3 no esta ordenado por probabilidad.")
    cursor.execute(
        EXEC_REGISTRAR,
        cliente_id, int(fila["documento_xml_id"]), 1, dataset_version_id,
        nombre_modelo, hash_modelo, hash_manifiesto, hash_variables_fila,
        plantillas[0], probabilidades[0], plantillas[1], probabilidades[1],
        plantillas[2], probabilidades[2],
    )
    columnas = [col[0] for col in cursor.description]
    resultado = cursor.fetchone()
    if resultado is None:
        raise RuntimeError("El procedimiento no devolvio una fila.")
    return dict(zip(columnas, resultado))


def ejecutar_prueba(*, carpeta_modelo: Path, paquete_modelo: Path,
                   servidor: str, base: str, driver: str, cliente_id: int,
                   documento_xml_ids: list[int], nombre_modelo: str,
                   publicar: bool) -> dict:
    manifiesto = cargar_manifiesto(carpeta_modelo, cliente_id)
    comprobar_entorno_modelo(manifiesto)
    dataset_version_id = int(manifiesto["dataset_version"]["DatasetVersionID"])
    hash_modelo = sha256_archivo(paquete_modelo)
    hash_manifiesto = hashlib.sha256((carpeta_modelo / "manifiesto.json").read_bytes()).hexdigest()

    connection = conectar_sql(servidor, base, driver)
    try:
        destino = query_frame(connection, DESTINO_SQL, ())
        if len(destino) != 1 or destino.iloc[0]["BaseActual"] != base:
            raise ValueError("La conexion SQL apunta a otra base de datos.")
        if publicar and (destino[["TablaID", "ProcedimientoID"]].isna().any().any()):
            raise ValueError("Falta la tabla o el procedimiento ml de predicciones en Azure SQL.")
        facturas = consultar_facturas_ids(connection, cliente_id, dataset_version_id, documento_xml_ids)
        variables = preparar_inferencia(facturas)
        from autogluon.tabular import TabularPredictor

        predictor = TabularPredictor.load(str(carpeta_modelo / "modelo"))
        predicciones = calcular_top3(facturas, variables, predictor)
        hashes = [hash_variables(variables.iloc[i]) for i in range(len(variables))]
        xml_ids = predicciones["documento_xml_id"].astype(int).tolist()
        if xml_ids != facturas["DocumentoXmlID"].astype(int).tolist():
            raise ValueError("Se altero el orden de los XML durante la inferencia.")

        resumen = {
            "cliente_id": cliente_id,
            "dataset_version_id": dataset_version_id,
            "documento_xml_ids": xml_ids,
            "modelo_artefacto_sha256": hash_modelo,
            "manifiesto_sha256": hash_manifiesto,
            "hash_variables_sha256": dict(zip(xml_ids, hashes)),
            "top3": [
                {
                    "documento_xml_id": int(fila["documento_xml_id"]),
                    "opciones": [
                        {
                            "plantilla": str(fila[f"plantilla_top{puesto}"]),
                            "probabilidad": float(fila[f"probabilidad_top{puesto}"]),
                        }
                        for puesto in (1, 2, 3)
                    ],
                }
                for _, fila in predicciones.iterrows()
            ],
        }
        if not publicar:
            return {**resumen, "resultado": "SOLO_VALIDACION", "filas_sql_escritas": 0}

        cursor = connection.cursor()
        transaccion_abierta = False
        try:
            cursor.execute("BEGIN TRANSACTION;")
            transaccion_abierta = True
            primera = [
                _registrar(
                    cursor, cliente_id=cliente_id, dataset_version_id=dataset_version_id,
                    nombre_modelo=nombre_modelo, hash_modelo=hash_modelo,
                    hash_manifiesto=hash_manifiesto, hash_variables_fila=hashes[i],
                    fila=predicciones.iloc[i],
                )
                for i in range(len(predicciones))
            ]
            segunda = [
                _registrar(
                    cursor, cliente_id=cliente_id, dataset_version_id=dataset_version_id,
                    nombre_modelo=nombre_modelo, hash_modelo=hash_modelo,
                    hash_manifiesto=hash_manifiesto, hash_variables_fila=hashes[i],
                    fila=predicciones.iloc[i],
                )
                for i in range(len(predicciones))
            ]
            if any(a["PrediccionPlantillaID"] != b["PrediccionPlantillaID"] for a, b in zip(primera, segunda)):
                raise RuntimeError("El reintento cambio un PrediccionPlantillaID.")
            if any(b["Resultado"] != "YA_EXISTE" for b in segunda):
                raise RuntimeError("El reintento no devolvio YA_EXISTE para todos los XML.")
            cursor.execute("COMMIT TRANSACTION;")
            transaccion_abierta = False
        except Exception:
            if transaccion_abierta:
                try:
                    cursor.execute("IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;")
                except Exception:
                    pass
            raise
        finally:
            cursor.close()
        return {
            **resumen,
            "resultado": "PUBLICADA_E_IDEMPOTENCIA_VERIFICADA",
            "primera_pasada": [
                {"documento_xml_id": int(f["DocumentoXmlID"]),
                 "prediccion_plantilla_id": int(f["PrediccionPlantillaID"]),
                 "resultado": f["Resultado"], "estado_revision": f["EstadoRevision"]}
                for f in primera
            ],
            "segunda_pasada": {"YA_EXISTE": len(segunda)},
        }
    finally:
        connection.close()
