"""Ejecuta un lote de inferencia ML desde Blob hacia Azure SQL.

Por defecto solo valida. --publicar habilita las escrituras idempotentes.
Con --xml-ids prueba facturas explicitas; sin el, toma hasta --limite pendientes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia.ejecutor_lotes import ejecutar  # noqa: E402
from scripts.probar_inferencia_blob_azure_sql import (  # noqa: E402
    BLOB, CONTENEDOR, CUENTA, SHA_MANIFIESTO, SHA_PAQUETE,
)


def main(argv: list[str] | None = None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cuenta", default=os.getenv("ML_MODELO_STORAGE_ACCOUNT", CUENTA))
    parser.add_argument("--contenedor", default=os.getenv("ML_MODELO_CONTAINER", CONTENEDOR))
    parser.add_argument("--blob", default=os.getenv("ML_MODELO_BLOB", BLOB))
    parser.add_argument("--sha256-paquete", default=os.getenv("ML_MODELO_SHA256", SHA_PAQUETE))
    parser.add_argument("--sha256-manifiesto", default=os.getenv("ML_MANIFIESTO_SHA256", SHA_MANIFIESTO))
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument("--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"))
    parser.add_argument("--cliente-id", type=int, default=1)
    parser.add_argument("--nombre-modelo", default="AutoGluon_Tabular_DatasetV1")
    parser.add_argument("--limite", type=int, default=3,
                        help="Maximo 100 facturas pendientes por ejecucion; por defecto 3.")
    parser.add_argument("--xml-ids", help="De 1 a 10 DocumentoXmlID explicitos, separados por coma.")
    parser.add_argument("--publicar", action="store_true",
                        help="Registra predicciones; sin esta bandera solo valida.")
    args = parser.parse_args(argv)
    if not args.servidor or not args.base:
        parser.error("Configura DIAN_SQL_SERVER y DIAN_SQL_DATABASE.")
    if not 1 <= args.limite <= 100:
        parser.error("--limite debe estar entre 1 y 100.")
    xml_ids = None
    if args.xml_ids is not None:
        try:
            xml_ids = [int(valor.strip()) for valor in args.xml_ids.split(",")]
        except ValueError:
            parser.error("--xml-ids requiere enteros separados por coma.")
        if not 1 <= len(xml_ids) <= 10 or any(i <= 0 for i in xml_ids) or len(set(xml_ids)) != len(xml_ids):
            parser.error("--xml-ids admite de 1 a 10 identificadores positivos y distintos.")
    resultado = ejecutar(
        cuenta=args.cuenta, contenedor=args.contenedor, blob=args.blob,
        sha_paquete=args.sha256_paquete, sha_manifiesto=args.sha256_manifiesto,
        servidor=args.servidor, base=args.base, driver=args.driver,
        cliente_id=args.cliente_id, nombre_modelo=args.nombre_modelo,
        limite=args.limite, xml_ids=xml_ids, publicar=args.publicar,
    )
    print(json.dumps(resultado, ensure_ascii=False, indent=2, default=str))
    return resultado


if __name__ == "__main__":
    main()
