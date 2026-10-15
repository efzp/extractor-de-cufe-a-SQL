"""Prueba acotada de inferencia y publicacion idempotente en Azure SQL."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia.publicacion import ejecutar_prueba  # noqa: E402


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modelo-dir", type=Path, required=True)
    parser.add_argument("--modelo-paquete", type=Path, required=True,
                        help="Archivo tar.gz identico al cargado en Blob; se calcula su SHA-256.")
    parser.add_argument("--xml-ids", required=True,
                        help="Lista explicita de DocumentoXmlID separados por coma (maximo 100).")
    parser.add_argument("--cliente-id", type=int, default=1)
    parser.add_argument("--nombre-modelo", default="AutoGluon_Tabular_DatasetV1")
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument("--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"))
    parser.add_argument("--publicar", action="store_true",
                        help="Escribe en SQL y repite el registro para comprobar idempotencia.")
    args = parser.parse_args(argv)
    if not args.servidor or not args.base:
        parser.error("Indica --servidor y --base, o configura DIAN_SQL_SERVER y DIAN_SQL_DATABASE.")
    if args.cliente_id <= 0 or not args.nombre_modelo.strip() or len(args.nombre_modelo.strip()) > 120:
        parser.error("ClienteID o NombreModelo no valido.")
    try:
        xml_ids = [int(item.strip()) for item in args.xml_ids.split(",")]
    except ValueError:
        parser.error("--xml-ids requiere enteros separados por coma.")
    resultado = ejecutar_prueba(
        carpeta_modelo=args.modelo_dir.expanduser().resolve(),
        paquete_modelo=args.modelo_paquete.expanduser().resolve(),
        servidor=args.servidor, base=args.base, driver=args.driver,
        cliente_id=args.cliente_id, documento_xml_ids=xml_ids,
        nombre_modelo=args.nombre_modelo.strip(), publicar=args.publicar,
    )
    print(json.dumps(resultado, ensure_ascii=False, indent=2, default=str))
    return resultado


if __name__ == "__main__":
    main()
