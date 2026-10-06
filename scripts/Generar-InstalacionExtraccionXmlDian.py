"""Genera un lote único, sin GO, desde los SQL fuente de extracción XML.

Uso: .venv\\Scripts\\python.exe scripts\\Generar-InstalacionExtraccionXmlDian.py
     .venv\\Scripts\\python.exe scripts\\Generar-InstalacionExtraccionXmlDian.py --check
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "scripts" / "Instalar-ExtraccionXmlDian.sql"
PROCEDURES = (
    "sp_ObtenerXmlParaExtraccion.sql",
    "sp_ListarXmlPendientesExtraccion.sql",
    "sp_RegistrarExtraccionXml.sql",
    "sp_RegistrarErrorExtraccionXml.sql",
)


def _read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig").strip()


def _dynamic_definition(definition: str, source: str) -> str:
    if not definition.startswith("CREATE OR ALTER "):
        raise ValueError(f"{source} no inicia con CREATE OR ALTER.")
    # Cada literal N'...' queda por debajo del límite de 4000 caracteres.
    chunks = [definition[i : i + 1800] for i in range(0, len(definition), 1800)]
    literals = ["N'" + part.replace("'", "''") + "'" for part in chunks]
    expression = "CAST(" + literals[0] + " AS nvarchar(max))"
    if len(literals) > 1:
        expression += "\n        + " + "\n        + ".join(literals[1:])
    return (
        f"    -- Fuente: {source}\n"
        f"    SET @Definicion = {expression};\n"
        "    EXEC sys.sp_executesql @Definicion;\n"
    )


def generate() -> str:
    migration = _read("sql/migrations/003_xml_extraction.sql")
    grants = _read("sql/security/dian_xml_extraction_grants.sql")
    sources = [f"sql/procedures/{name}" for name in PROCEDURES]
    source_view = "sql/views/vw_FacturaXmlMlV1.sql"
    parts = [
        "-- Instalación aditiva de extracción XML DIAN, en un solo envío al editor web de Azure SQL.\n"
        "-- No usa GO, no elimina objetos ni datos y se puede volver a ejecutar.\n"
        "-- Generado por scripts/Generar-InstalacionExtraccionXmlDian.py.\n"
        "-- Requiere el esquema base dian y el rol dian_runtime ya instalados.\n"
        "SET NOCOUNT ON;\nSET XACT_ABORT ON;\n\n"
        "IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'\n"
        "    THROW 50720, 'Conectado a una base distinta de sqldb-dian-xml-cpabaas-dev.', 1;\n"
        "IF NOT EXISTS (SELECT 1 FROM sys.database_principals\n"
        "               WHERE [name] = N'dian_runtime' AND [type] = 'R')\n"
        "    THROW 50721, 'Falta el rol dian_runtime; no se modifico nada.', 1;\n\n"
        "BEGIN TRY\n    BEGIN TRANSACTION;\n\n"
        "    -- Fuente: sql/migrations/003_xml_extraction.sql\n",
        migration + "\n\n",
        "    DECLARE @Definicion nvarchar(max);\n",
    ]
    for source in sources:
        parts.append(_dynamic_definition(_read(source), source))
        parts.append("\n")
    view = _read(source_view)
    view = "CREATE OR ALTER VIEW" + view.split("CREATE OR ALTER VIEW", 1)[1]
    parts.append(_dynamic_definition(view, source_view))
    parts.extend(
        [
            "\n    -- Fuente: sql/security/dian_xml_extraction_grants.sql\n",
            "    " + grants.replace("\n", "\n    ") + "\n\n",
            "    IF OBJECT_ID(N'dian.XmlExtraccion', N'U') IS NULL\n"
            "       OR OBJECT_ID(N'dian.XmlLinea', N'U') IS NULL\n"
            "       OR OBJECT_ID(N'dian.XmlExtraccionError', N'U') IS NULL\n"
            "       OR OBJECT_ID(N'dian.sp_ObtenerXmlParaExtraccion', N'P') IS NULL\n"
            "       OR OBJECT_ID(N'dian.sp_ListarXmlPendientesExtraccion', N'P') IS NULL\n"
            "       OR OBJECT_ID(N'dian.sp_RegistrarExtraccionXml', N'P') IS NULL\n"
            "       OR OBJECT_ID(N'dian.sp_RegistrarErrorExtraccionXml', N'P') IS NULL\n"
            "       OR OBJECT_ID(N'dian.vw_FacturaXmlMlV1', N'V') IS NULL\n"
            "        THROW 50722, 'Faltan objetos de extraccion XML; se revierte todo.', 1;\n\n"
            "    COMMIT TRANSACTION;\nEND TRY\nBEGIN CATCH\n"
            "    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;\n    THROW;\nEND CATCH;\n\n"
            "SELECT DB_NAME() AS [BaseActual],\n"
            "       (SELECT COUNT(*) FROM sys.tables WHERE [schema_id] = SCHEMA_ID(N'dian')\n"
            "          AND [name] IN (N'XmlExtraccion', N'XmlLinea', N'XmlExtraccionError')) AS [TablasExtraccion],\n"
            "       (SELECT COUNT(*) FROM sys.procedures WHERE [schema_id] = SCHEMA_ID(N'dian')\n"
            "          AND [name] IN (N'sp_ObtenerXmlParaExtraccion', N'sp_ListarXmlPendientesExtraccion',\n"
            "                         N'sp_RegistrarExtraccionXml', N'sp_RegistrarErrorExtraccionXml')) AS [ProcedimientosExtraccion],\n"
            "       (SELECT COUNT(*) FROM sys.views WHERE [schema_id] = SCHEMA_ID(N'dian')\n"
            "          AND [name] = N'vw_FacturaXmlMlV1') AS [VistasExtraccion];\n",
        ]
    )
    return "".join(parts)


def main() -> None:
    content = generate()
    if sys.argv[1:] == ["--check"]:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != content:
            raise SystemExit("El SQL integrado no coincide con los archivos fuente.")
        print(f"OK: {OUTPUT.name} coincide con sus fuentes")
    elif len(sys.argv) == 1:
        OUTPUT.write_text(content, encoding="utf-8", newline="\n")
        print(f"Generado: {OUTPUT}")
    else:
        raise SystemExit("Uso: Generar-InstalacionExtraccionXmlDian.py [--check]")


if __name__ == "__main__":
    main()
