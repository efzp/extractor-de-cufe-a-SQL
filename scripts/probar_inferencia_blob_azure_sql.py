"""Prueba local Blob -> AutoGluon -> Azure SQL, sin escrituras por defecto.

Descarga un artefacto fijado por SHA-256, verifica el manifiesto incluido,
calcula el top 3 de una lista explicita de DocumentoXmlID y, solo con
--publicar, comprueba la escritura idempotente en una transaccion SQL.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia.publicacion import ejecutar_prueba  # noqa: E402
from scripts.probar_modelo_linux import extraer_modelo_seguro, sha256_archivo  # noqa: E402


CUENTA = "stdianxmlcpabaasdev"
CONTENEDOR = "modelos-ml"
BLOB = "plantillas/dataset-v1/20261014T161302Z_e0d0db9a/modelo.tar.gz"
SHA_PAQUETE = "b0dcb976fcd986317dde055d322555b805a504c48325a117b63c5fdf90dac4a3"
SHA_MANIFIESTO = "448fbd444b7595cf442491d1c2f9e3b98217011ab430d4a7f69c284210ac9a36"
MAX_PAQUETE_BYTES = 1_000_000_000


def descargar_paquete(blob_client, destino: Path, sha_esperado: str) -> dict:
    """Rechaza metadata distinta, tamano anomalo o bytes diferentes al hash fijado."""
    propiedades = blob_client.get_blob_properties()
    tamano = int(propiedades.size)
    if tamano <= 0 or tamano > MAX_PAQUETE_BYTES:
        raise ValueError(f"Tamano del paquete Blob fuera de limite: {tamano} bytes.")
    metadata = propiedades.metadata or {}
    sha_metadata = str(metadata.get("sha256", "")).lower()
    if sha_metadata != sha_esperado:
        raise ValueError("El SHA-256 en metadatos Blob no coincide con el artefacto esperado.")

    digest = hashlib.sha256()
    recibidos = 0
    with destino.open("wb") as archivo:
        for bloque in blob_client.download_blob(max_concurrency=1).chunks():
            recibidos += len(bloque)
            if recibidos > tamano:
                raise ValueError("La descarga supera el tamano declarado por Blob.")
            digest.update(bloque)
            archivo.write(bloque)
    if recibidos != tamano or digest.hexdigest() != sha_esperado:
        raise ValueError("El tamano o SHA-256 del paquete descargado no coincide.")
    return {
        "bytes": recibidos,
        "sha256": digest.hexdigest(),
        "etag": str(propiedades.etag),
        "datasetversion_metadata": metadata.get("datasetversion"),
    }


def ejecutar(*, cuenta: str, contenedor: str, blob: str,
            sha_paquete: str, sha_manifiesto: str,
            servidor: str, base: str, driver: str,
            cliente_id: int, xml_ids: list[int], nombre_modelo: str,
            publicar: bool) -> dict:
    if len(xml_ids) < 1 or len(xml_ids) > 10 or any(i <= 0 for i in xml_ids) or len(set(xml_ids)) != len(xml_ids):
        raise ValueError("Esta prueba admite de 1 a 10 DocumentoXmlID positivos y distintos.")
    if not cuenta or not contenedor or not blob or not servidor or not base:
        raise ValueError("Faltan datos de Blob o Azure SQL.")
    if cliente_id <= 0 or not nombre_modelo.strip() or len(nombre_modelo.strip()) > 120:
        raise ValueError("ClienteID o NombreModelo no valido.")
    for valor in (sha_paquete, sha_manifiesto):
        if len(valor) != 64 or any(c not in "0123456789abcdef" for c in valor):
            raise ValueError("Los SHA-256 esperados deben ser hexadecimales en minusculas.")

    from azure.identity import AzureCliCredential
    from azure.storage.blob import BlobServiceClient

    with tempfile.TemporaryDirectory(prefix="dian_ml_blob_sql_") as temporal:
        carpeta = Path(temporal)
        paquete = carpeta / "modelo.tar.gz"
        with AzureCliCredential() as credencial:
            with BlobServiceClient(
                account_url=f"https://{cuenta}.blob.core.windows.net",
                credential=credencial,
            ) as servicio:
                cliente = servicio.get_blob_client(container=contenedor, blob=blob)
                descarga = descargar_paquete(cliente, paquete, sha_paquete)

        extraer_modelo_seguro(paquete, carpeta)
        ruta_manifiesto = carpeta / "manifiesto.json"
        if sha256_archivo(ruta_manifiesto) != sha_manifiesto:
            raise ValueError("El manifiesto incluido en Blob no coincide con el SHA-256 esperado.")
        metadata_version = descarga["datasetversion_metadata"]
        manifest = json.loads(ruta_manifiesto.read_text(encoding="utf-8"))
        version = int(manifest.get("dataset_version", {}).get("DatasetVersionID", 0))
        if metadata_version is None or str(metadata_version) != str(version):
            raise ValueError("La version del dataset en Blob no coincide con el manifiesto.")

        resultado = ejecutar_prueba(
            carpeta_modelo=carpeta, paquete_modelo=paquete,
            servidor=servidor, base=base, driver=driver,
            cliente_id=cliente_id, documento_xml_ids=xml_ids,
            nombre_modelo=nombre_modelo.strip(), publicar=publicar,
        )
        return {
            "origen_modelo": {"cuenta": cuenta, "contenedor": contenedor,
                              "blob": blob, **descarga},
            **resultado,
        }


def main(argv: list[str] | None = None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cuenta", default=CUENTA)
    parser.add_argument("--contenedor", default=CONTENEDOR)
    parser.add_argument("--blob", default=BLOB)
    parser.add_argument("--sha256-paquete", default=SHA_PAQUETE)
    parser.add_argument("--sha256-manifiesto", default=SHA_MANIFIESTO)
    parser.add_argument("--xml-ids", required=True,
                        help="De 1 a 10 DocumentoXmlID explicitos, separados por coma.")
    parser.add_argument("--cliente-id", type=int, default=1)
    parser.add_argument("--nombre-modelo", default="AutoGluon_Tabular_DatasetV1")
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument("--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"))
    parser.add_argument("--publicar", action="store_true",
                        help="Registra top 3 y verifica idempotencia. Sin esta opcion, solo lectura.")
    args = parser.parse_args(argv)
    try:
        xml_ids = [int(valor.strip()) for valor in args.xml_ids.split(",")]
    except ValueError:
        parser.error("--xml-ids requiere enteros separados por coma.")
    resultado = ejecutar(
        cuenta=args.cuenta, contenedor=args.contenedor, blob=args.blob,
        sha_paquete=args.sha256_paquete, sha_manifiesto=args.sha256_manifiesto,
        servidor=args.servidor, base=args.base, driver=args.driver,
        cliente_id=args.cliente_id, xml_ids=xml_ids,
        nombre_modelo=args.nombre_modelo, publicar=args.publicar,
    )
    print(json.dumps(resultado, ensure_ascii=False, indent=2, default=str))
    return resultado


if __name__ == "__main__":
    main()
