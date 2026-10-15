"""Actualiza y prueba la idempotencia de ml.sp_RegistrarPrediccionPlantilla en dev.

Sin --aplicar solo compara la definicion desplegada con la fuente anterior.
Con --aplicar exige que la definicion anterior sea la esperada, actualiza el
procedimiento y comprueba reintentos equivalentes y conflictos reales.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from decimal import Decimal
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from ml_inferencia.publicacion import EXEC_REGISTRAR  # noqa: E402
from scripts.entrenar_modelo_azure_sql import conectar_sql  # noqa: E402


SQL_PATH = ROOT / "sql" / "procedures" / "sp_RegistrarPrediccionPlantilla.sql"
NOMBRE_BASE = "sqldb-dian-xml-cpabaas-dev"
COMENTARIO_TOLERANCIA = """    -- Las probabilidades de AutoGluon pueden variar unas unidades en la
    -- octava cifra decimal entre ejecuciones del mismo artefacto. Solo se
    -- tolera esa variacion si modelo, variables y las tres plantillas son iguales.
    DECLARE @ToleranciaProbabilidad decimal(18,12) = 0.000001000000;
"""
FILTRO_SNAPSHOT = """        -- DatasetFila guarda solo etiquetas aceptadas. La fuente del snapshot
        -- incluyo tambien facturas historicas sin match aceptado.
        IF EXISTS
        (
            SELECT 1
            FROM [dian].[XmlExtraccion] AS e
            JOIN [ml].[DatasetVersion] AS d
              ON d.[DatasetVersionID] = @DatasetVersionID
            WHERE e.[DocumentoXmlID] = @DocumentoXmlID
              AND e.[VersionExtractor] = @VersionExtractor
              AND e.[FechaExtraccionUTC] <= d.[FechaCreacionUTC]
        )
            THROW 50920, 'El XML pertenece a la poblacion historica del snapshot; no se registra inferencia.', 1;

"""


def normalizar(sql: str) -> str:
    sql = sql.replace("\r\n", "\n")
    encabezado = re.search(r"(?im)^\s*CREATE\s+(?:OR\s+ALTER\s+)?PROCEDURE\b", sql)
    if encabezado is None:
        raise ValueError(f"Encabezado SQL inesperado: {sql[:140]!r}")
    return ("CREATE OR ALTER PROCEDURE" + sql[encabezado.end():]).strip()


def fuente_tolerancia(nueva: str) -> str:
    if nueva.count(FILTRO_SNAPSHOT) != 1:
        raise ValueError("No se encontro un unico filtro de snapshot en la fuente.")
    return nueva.replace(FILTRO_SNAPSHOT, "")


def fuente_anterior(nueva: str) -> str:
    anterior = fuente_tolerancia(nueva)
    if anterior.count(COMENTARIO_TOLERANCIA) != 1:
        raise ValueError("No se encontro una unica declaracion de tolerancia en la fuente.")
    anterior = anterior.replace(COMENTARIO_TOLERANCIA, "")
    for numero in (1, 2, 3):
        nuevo = (
            f"                  AND ABS(CONVERT(decimal(18,12), [ProbabilidadTop{numero}]) "
            f"- @ProbabilidadTop{numero})\n"
            "                      <= @ToleranciaProbabilidad"
        )
        if anterior.count(nuevo) != 1:
            raise ValueError(f"No se encontro una unica comparacion del top {numero}.")
        anterior = anterior.replace(nuevo, f"                  AND [ProbabilidadTop{numero}] = @P{numero}")
    return anterior


def parametros_fila(fila, *, desviacion: Decimal = Decimal(0),
                    cambiar_hash: bool = False, cambiar_plantilla: bool = False) -> tuple:
    hash_variables = str(fila.HashVariablesSha256).strip()
    if cambiar_hash:
        hash_variables = ("0" if hash_variables[0] != "0" else "1") + hash_variables[1:]
    plantilla1 = str(fila.PlantillaTop1) + ("_CAMBIADA" if cambiar_plantilla else "")
    return (
        int(fila.ClienteID), int(fila.DocumentoXmlID), int(fila.VersionExtractor),
        int(fila.DatasetVersionID), str(fila.NombreModelo),
        str(fila.ModeloArtefactoSha256).strip(), str(fila.ManifiestoSha256).strip(),
        hash_variables, plantilla1, Decimal(fila.ProbabilidadTop1) + desviacion,
        str(fila.PlantillaTop2), Decimal(fila.ProbabilidadTop2),
        str(fila.PlantillaTop3), Decimal(fila.ProbabilidadTop3),
    )


def comprobar_contrato(connection, documento_xml_id: int) -> dict:
    cursor = connection.cursor()
    try:
        cursor.execute("""
            SELECT TOP (1) d.ClienteID, p.*
            FROM ml.PrediccionPlantilla AS p
            JOIN ml.DatasetVersion AS d ON d.DatasetVersionID = p.DatasetVersionID
            WHERE p.DocumentoXmlID = ?
            ORDER BY p.PrediccionPlantillaID;
        """, documento_xml_id)
        fila = cursor.fetchone()
        if fila is None:
            raise ValueError(f"No hay prediccion existente para XML {documento_xml_id}.")
        id_original = int(fila.PrediccionPlantillaID)
        rowversion_original = bytes(fila.RowVersion)

        cursor.execute(EXEC_REGISTRAR, *parametros_fila(fila, desviacion=Decimal("0.00000050")))
        resultado = cursor.fetchone()
        if resultado is None or int(resultado.PrediccionPlantillaID) != id_original or resultado.Resultado != "YA_EXISTE":
            raise AssertionError("La variacion menor a la tolerancia no devolvio YA_EXISTE.")

        for escenario, cambios in (
            ("probabilidad_fuera_tolerancia", {"desviacion": Decimal("0.00000200")}),
            ("hash_variables_distinto", {"cambiar_hash": True}),
            ("plantilla_distinta", {"cambiar_plantilla": True}),
        ):
            try:
                cursor.execute(EXEC_REGISTRAR, *parametros_fila(fila, **cambios))
            except Exception as error:
                if "50917" not in str(error):
                    raise AssertionError(f"{escenario} produjo otro error: {error}") from error
            else:
                raise AssertionError(f"{escenario} fue aceptado indebidamente.")

        cursor.execute(
            "SELECT PrediccionPlantillaID, RowVersion "
            "FROM ml.PrediccionPlantilla WHERE DocumentoXmlID = ? "
            "AND ModeloArtefactoSha256 = ?;",
            int(fila.DocumentoXmlID), str(fila.ModeloArtefactoSha256),
        )
        filas_finales = cursor.fetchall()
        if (len(filas_finales) != 1 or int(filas_finales[0][0]) != id_original
                or bytes(filas_finales[0][1]) != rowversion_original):
            raise AssertionError("La prueba altero o duplico una prediccion existente.")
        return {"documento_xml_id": documento_xml_id, "prediccion_plantilla_id": id_original,
                "tolerancia_aceptada": "0.00000050", "conflictos_rechazados": 3,
                "fila_existente_sin_cambios": True}
    finally:
        cursor.close()


def ejecutar(servidor: str, base: str, driver: str, xml_id: int, aplicar: bool) -> dict:
    if base != NOMBRE_BASE:
        raise ValueError(f"Solo se permite aplicar el contrato en {NOMBRE_BASE}.")
    if xml_id <= 0:
        raise ValueError("DocumentoXmlID de prueba invalido.")
    nueva = normalizar(SQL_PATH.read_text(encoding="utf-8"))
    anterior = fuente_anterior(nueva)
    tolerancia = fuente_tolerancia(nueva)
    connection = conectar_sql(servidor, base, driver)
    try:
        cursor = connection.cursor()
        try:
            cursor.execute("SELECT DB_NAME(), OBJECT_DEFINITION(OBJECT_ID(N'ml.sp_RegistrarPrediccionPlantilla', N'P'));")
            fila = cursor.fetchone()
            if fila is None or fila[0] != NOMBRE_BASE or fila[1] is None:
                raise ValueError("Base u objeto SQL inesperado.")
            actual = normalizar(fila[1])
            estado = (
                "ANTERIOR" if actual == anterior else
                "TOLERANCIA" if actual == tolerancia else
                "ACTUALIZADO" if actual == nueva else "DIFERENTE"
            )
            if estado == "DIFERENTE":
                raise ValueError("La definicion desplegada no coincide con la anterior ni con la nueva; no se sobrescribio.")
            if not aplicar:
                return {"base": base, "estado_actual": estado, "aplicado": False}
            if estado in ("ANTERIOR", "TOLERANCIA"):
                cursor.execute(nueva)
                cursor.execute("SELECT OBJECT_DEFINITION(OBJECT_ID(N'ml.sp_RegistrarPrediccionPlantilla', N'P'));")
                if normalizar(cursor.fetchone()[0]) != nueva:
                    raise RuntimeError("La definicion nueva no quedo instalada exactamente.")
        finally:
            cursor.close()
        return {"base": base, "estado_anterior": estado, "aplicado": estado in ("ANTERIOR", "TOLERANCIA"),
                "prueba": comprobar_contrato(connection, xml_id)}
    finally:
        connection.close()


def main(argv: list[str] | None = None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE", NOMBRE_BASE))
    parser.add_argument("--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"))
    parser.add_argument("--xml-id-prueba", type=int, default=471)
    parser.add_argument("--aplicar", action="store_true")
    args = parser.parse_args(argv)
    if not args.servidor:
        parser.error("Indica --servidor o configura DIAN_SQL_SERVER.")
    resultado = ejecutar(args.servidor, args.base, args.driver, args.xml_id_prueba, args.aplicar)
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return resultado


if __name__ == "__main__":
    main()
