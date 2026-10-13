"""Genera un lote SQL unico, sin GO, para instalar el dataset ML v1.

Uso: python scripts/Generar-InstalacionDatasetEntrenamientoMl.py [--check]
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "scripts" / "Instalar-DatasetEntrenamientoMl.sql"


def _read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig").strip()


def _dynamic_definition(relative: str, marker: str) -> str:
    source = _read(relative)
    if marker not in source:
        raise ValueError(f"No se encontro {marker} en {relative}")
    definition = marker + source.split(marker, 1)[1]
    # Los literales Unicode individuales deben quedar por debajo de 4000 caracteres.
    chunks = [definition[i : i + 1800] for i in range(0, len(definition), 1800)]
    literals = ["N'" + chunk.replace("'", "''") + "'" for chunk in chunks]
    expression = "CAST(" + literals[0] + " AS nvarchar(max))"
    expression += "".join("\n        + " + literal for literal in literals[1:])
    return (
        f"    -- Fuente: {relative}\n"
        f"    SET @Definicion = {expression};\n"
        "    EXEC sys.sp_executesql @Definicion;\n\n"
    )


def generate() -> str:
    migration = _read("sql/migrations/005_ml_dataset.sql")
    view = _dynamic_definition(
        "sql/views/vw_FacturaOrigenMlV1.sql", "CREATE OR ALTER VIEW"
    )
    procedure = _dynamic_definition(
        "sql/procedures/sp_PublicarDatasetEntrenamientoV1.sql",
        "CREATE OR ALTER PROCEDURE",
    )
    return "".join(
        [
            "-- Instalacion aditiva del dataset de entrenamiento ML v1 en Azure SQL.\n"
            "-- Un solo envio, sin GO. No elimina objetos ni datos. No vuelve a instalar objetos existentes.\n"
            "-- Generado por scripts/Generar-InstalacionDatasetEntrenamientoMl.py.\n"
            "SET NOCOUNT ON;\nSET XACT_ABORT ON;\n\n"
            "IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'\n"
            "    THROW 50830, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;\n"
            "IF OBJECT_ID(N'dian.Cliente', N'U') IS NULL\n"
            "   OR OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL\n"
            "   OR OBJECT_ID(N'dian.vw_FacturaXmlMlV1', N'V') IS NULL\n"
            "    THROW 50831, 'Faltan objetos base de DIAN; no se modifico nada.', 1;\n"
            "IF OBJECT_ID(N'ml.DatasetVersion', N'U') IS NOT NULL\n"
            "   OR OBJECT_ID(N'ml.DatasetFila', N'U') IS NOT NULL\n"
            "   OR OBJECT_ID(N'ml.vw_FacturaOrigenMlV1', N'V') IS NOT NULL\n"
            "   OR OBJECT_ID(N'ml.sp_PublicarDatasetEntrenamientoV1', N'P') IS NOT NULL\n"
            "    THROW 50832, 'Ya existen objetos ML; no se modifico nada.', 1;\n\n"
            "BEGIN TRY\n    BEGIN TRANSACTION;\n\n"
            "    -- Fuente: sql/migrations/005_ml_dataset.sql\n",
            "    " + migration.replace("\n", "\n    ") + "\n\n",
            "    DECLARE @Definicion nvarchar(max);\n",
            view,
            procedure,
            "    IF OBJECT_ID(N'ml.DatasetVersion', N'U') IS NULL\n"
            "       OR OBJECT_ID(N'ml.DatasetFila', N'U') IS NULL\n"
            "       OR OBJECT_ID(N'ml.vw_FacturaOrigenMlV1', N'V') IS NULL\n"
            "       OR OBJECT_ID(N'ml.sp_PublicarDatasetEntrenamientoV1', N'P') IS NULL\n"
            "        THROW 50833, 'Faltan objetos ML; se revierte la instalacion.', 1;\n\n"
            "    COMMIT TRANSACTION;\nEND TRY\nBEGIN CATCH\n"
            "    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;\n    THROW;\nEND CATCH;\n\n"
            "SELECT DB_NAME() AS [BaseActual],\n"
            "       (SELECT COUNT(*) FROM sys.tables WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [TablasMl],\n"
            "       (SELECT COUNT(*) FROM sys.views WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [VistasMl],\n"
            "       (SELECT COUNT(*) FROM sys.procedures WHERE [schema_id] = SCHEMA_ID(N'ml')) AS [ProcedimientosMl];\n",
        ]
    )


def main() -> None:
    content = generate()
    if sys.argv[1:] == ["--check"]:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != content:
            raise SystemExit("El SQL integrado no coincide con sus archivos fuente.")
        print(f"OK: {OUTPUT.name} coincide con sus fuentes")
    elif len(sys.argv) == 1:
        OUTPUT.write_text(content, encoding="utf-8", newline="\n")
        print(f"Generado: {OUTPUT}")
    else:
        raise SystemExit("Uso: Generar-InstalacionDatasetEntrenamientoMl.py [--check]")


if __name__ == "__main__":
    main()
