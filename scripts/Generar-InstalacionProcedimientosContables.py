"""Genera un solo lote sin GO para instalar los tres procedimientos contables.

Uso: python scripts/Generar-InstalacionProcedimientosContables.py [--check]
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "scripts" / "Instalar-ProcedimientosContables.sql"
PROCEDURES = (
    "sp_IniciarCargaContable",
    "sp_RegistrarMovimientoContable",
    "sp_FinalizarCargaContable",
)


def generate() -> str:
    parts = [
        "-- Instalacion de los tres procedimientos contables en una sola ejecucion.\n"
        "-- Requiere sql/migrations/004_contabilidad_historica.sql ya instalado.\n"
        "-- No crea tablas, no elimina datos y puede volver a ejecutarse.\n"
        "-- Generado por scripts/Generar-InstalacionProcedimientosContables.py.\n"
        "SET NOCOUNT ON;\nSET XACT_ABORT ON;\nSET ANSI_NULLS ON;\nSET QUOTED_IDENTIFIER ON;\n\n"
        "IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'\n"
        "    THROW 50880, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;\n"
        "IF OBJECT_ID(N'contabilidad.CargaArchivo', N'U') IS NULL\n"
        "   OR OBJECT_ID(N'contabilidad.MovimientoHistorico', N'U') IS NULL\n"
        "   OR OBJECT_ID(N'contabilidad.CargaMovimiento', N'U') IS NULL\n"
        "    THROW 50881, 'Faltan las tablas de la migracion contable 004; no se modifico nada.', 1;\n"
        "IF NOT EXISTS (SELECT 1 FROM sys.database_principals\n"
        "               WHERE [name] = N'dian_runtime' AND [type] = 'R')\n"
        "    THROW 50882, 'Falta el rol dian_runtime; no se modifico nada.', 1;\n\n"
        "BEGIN TRY\n    BEGIN TRANSACTION;\n\n"
        "    DECLARE @Definicion nvarchar(max);\n"
        "    DECLARE @Paso nvarchar(128) = N'inicio';\n\n"
    ]
    for name in PROCEDURES:
        source = f"sql/procedures/{name}.sql"
        definition = (ROOT / source).read_text(encoding="utf-8-sig").strip()
        if not definition.startswith("CREATE OR ALTER PROCEDURE "):
            raise ValueError(f"{source} no inicia con CREATE OR ALTER PROCEDURE.")
        chunks: list[str] = []
        chunk = ""
        for line in definition.splitlines(keepends=True):
            if len(line) > 1800:
                raise ValueError(f"{source} contiene una linea demasiado larga.")
            if chunk and len(chunk) + len(line) > 1800:
                chunks.append(chunk)
                chunk = ""
            chunk += line
        if chunk:
            chunks.append(chunk)
        literals = ["N'" + chunk.replace("'", "''") + "'" for chunk in chunks]
        expression = "CAST(" + literals[0] + " AS nvarchar(max))"
        if len(literals) > 1:
            expression += "\n        + " + "\n        + ".join(literals[1:])
        parts.append(
            f"    -- Fuente: {source}\n"
            f"    SET @Paso = N'{name}';\n"
            f"    SET @Definicion = {expression};\n"
            "    EXEC sys.sp_executesql @Definicion;\n\n"
        )
    grants = (ROOT / "sql/security/contabilidad_runtime_grants.sql").read_text(
        encoding="utf-8-sig"
    ).strip()
    parts.extend(
        [
            "    -- Fuente: sql/security/contabilidad_runtime_grants.sql\n",
            "    " + grants.replace("\n", "\n    ") + "\n\n",
            "    COMMIT TRANSACTION;\nEND TRY\nBEGIN CATCH\n"
            "    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;\n"
            "    DECLARE @DetalleError nvarchar(2048) = LEFT(CONCAT(\n"
            "        N'Paso: ', @Paso, N'; error SQL ', ERROR_NUMBER(),\n"
            "        N'; linea ', ERROR_LINE(), N': ', ERROR_MESSAGE()), 2048);\n"
            "    THROW 50883, @DetalleError, 1;\nEND CATCH;\n\n"
            "SELECT DB_NAME() AS [BaseActual],\n"
            "       (SELECT COUNT(*) FROM sys.procedures\n"
            "        WHERE [schema_id] = SCHEMA_ID(N'contabilidad')\n"
            "          AND [name] IN (N'sp_IniciarCargaContable',\n"
            "                         N'sp_RegistrarMovimientoContable',\n"
            "                         N'sp_FinalizarCargaContable')) AS [ProcedimientosContables];\n",
        ]
    )
    return "".join(parts)


def main() -> None:
    content = generate()
    if sys.argv[1:] == ["--check"]:
        if OUTPUT.read_text(encoding="utf-8-sig") != content:
            raise SystemExit(f"{OUTPUT} no coincide con los archivos fuente.")
        print(f"OK: {OUTPUT} coincide con los archivos fuente.")
    elif not sys.argv[1:]:
        OUTPUT.write_text(content, encoding="utf-8", newline="\n")
        print(f"Generado: {OUTPUT}")
    else:
        raise SystemExit("Uso: [--check]")


if __name__ == "__main__":
    main()
