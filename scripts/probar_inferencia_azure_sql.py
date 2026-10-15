"""Prueba local, de solo lectura, de un modelo AutoGluon con Azure SQL."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia.service import ejecutar  # noqa: E402


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modelo-dir", type=Path, required=True,
                        help="Carpeta local que contiene modelo/ y manifiesto.json.")
    parser.add_argument("--cliente-id", type=int, default=1)
    parser.add_argument("--limite", type=int, default=10)
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument("--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"))
    parser.add_argument("--salida", type=Path, required=True,
                        help="Carpeta local para los CSV de auditoria; usa una ruta fuera del repositorio.")
    parser.add_argument("--solo-validar", action="store_true",
                        help="Comprueba SQL y las variables sin cargar AutoGluon ni generar archivos.")
    args = parser.parse_args(argv)
    if not args.servidor or not args.base:
        parser.error("Indica --servidor y --base, o configura DIAN_SQL_SERVER y DIAN_SQL_DATABASE.")
    if args.cliente_id <= 0 or not 1 <= args.limite <= 100:
        parser.error("--cliente-id debe ser positivo y --limite debe estar entre 1 y 100.")
    resultado = ejecutar(
        carpeta_modelo=args.modelo_dir.expanduser().resolve(),
        servidor=args.servidor, base=args.base, driver=args.driver,
        cliente_id=args.cliente_id, limite=args.limite,
        salida_base=args.salida, solo_validar=args.solo_validar,
    )
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return resultado


if __name__ == "__main__":
    main()
