"""Valida el matching historico usando facturas y movimientos de Azure SQL.

Solo ejecuta SELECT. No importa run_pipeline.py (que ejecuta trabajo al importar),
no entrena un modelo y no modifica las tablas de Azure SQL.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import struct
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


FACTURAS_SQL = """
SELECT v.*
FROM [dian].[vw_FacturaXmlMlV1] AS v
WHERE EXISTS
(
    SELECT 1
    FROM [dian].[Documento] AS d
    WHERE d.[ClienteID] = ?
      AND d.[ClaveDocumento] = v.[cufe]
      AND CONCAT(N'dian:', d.[PrimeraCargaID]) = v.[id_carga]
)
"""

FILTRO_CARGA_SQL = """
AND EXISTS
(
    SELECT 1
    FROM [dian].[Documento] AS d
    JOIN [dian].[CargaDocumento] AS cd
      ON cd.[DocumentoID] = d.[DocumentoID]
    WHERE d.[ClienteID] = ?
      AND d.[ClaveDocumento] = v.[cufe]
      AND cd.[CargaArchivoID] = ?
      AND cd.[EsValida] = 1
)
"""

MOVIMIENTOS_SQL = """
SELECT
    [Fecha] AS [FECHA],
    [TipoDoc] AS [TIPODOC],
    [NumDoc] AS [NUMDOC],
    [Cuenta] AS [CUENTA],
    [NomCuenta] AS [NOM_CUENTA],
    [IdentidadTercero] AS [IDENTIDADTERCERO],
    [NombreTercero] AS [NOMBRETERCERO],
    [Concepto] AS [CONCEPTO],
    [Centro] AS [CENTRO],
    [CC] AS [C_C],
    [CodigoUsuario] AS [CODIGO_USUARIO],
    [DocFuente] AS [DOC_FUENTE],
    [NomCentro] AS [NOM_CENTRO],
    [Debito] AS [DEBITO],
    [Credito] AS [CREDITO]
FROM [contabilidad].[MovimientoHistorico]
WHERE [ClienteID] = ? AND [FuenteContable] = ?
ORDER BY [Fecha], [MovimientoID];
"""

# Mismo mapeo usado por run_pipeline.py; no se importa ese modulo porque
# ejecuta el pipeline completo como efecto lateral.
COLUMNAS_MOVIMIENTOS = {
    "fecha_mov": "FECHA",
    "tipo_doc": "TIPODOC",
    "numero_doc": "NUMDOC",
    "cuenta": "CUENTA",
    "nombre_cuenta": "NOM_CUENTA",
    "identidad": "IDENTIDADTERCERO",
    "nombre_tercero": "NOMBRETERCERO",
    "concepto": "CONCEPTO",
    "codigo_centro_costo": "CENTRO",
    "centro_costo": "C_C",
    "usuario": "CODIGO_USUARIO",
    "numero_movil": "DOC_FUENTE",
    "nombre_centro_costo": "NOM_CENTRO",
    "debito": "DEBITO",
    "credito": "CREDITO",
}

ESTADOS_OK = frozenset(("OK_UNICO", "OK_TEXTO", "OK_VALOR"))
COLUMNAS_REPORTE = (
    "cufe", "id_factura", "nit_proveedor", "fecha_emision",
    "total_factura", "llave_factura", "estado_match", "llave_asiento",
    "score_total", "motivo_score", "fecha_asiento", "monto_asiento",
    "n_lineas", "target_plantilla_cuentas",
)


def argumentos(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scripts-historicos", type=Path, required=True,
        help="Carpeta que contiene procesamiento_facturas_contabilidad_match.py y su modulo de limpieza.",
    )
    parser.add_argument("--cliente-id", type=int, default=1)
    parser.add_argument("--fuente-contable", default="ERP_CPA_BAAS")
    parser.add_argument(
        "--carga-dian-id", type=int,
        help="Limita las facturas a las filas validas de esta carga; los movimientos historicos siguen completos.",
    )
    parser.add_argument(
        "--referencia", type=Path,
        help="Match historico .xlsx para comparar llave_factura, estado_match y llave_asiento.",
    )
    parser.add_argument("--salida", type=Path, required=True)
    parser.add_argument("--servidor", default=os.getenv("DIAN_SQL_SERVER"))
    parser.add_argument("--base", default=os.getenv("DIAN_SQL_DATABASE"))
    parser.add_argument(
        "--driver", default=os.getenv("DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server")
    )
    args = parser.parse_args(argv)
    if args.cliente_id <= 0 or (args.carga_dian_id is not None and args.carga_dian_id <= 0):
        parser.error("--cliente-id y --carga-dian-id deben ser positivos.")
    if not args.fuente_contable.strip():
        parser.error("--fuente-contable no puede estar vacia.")
    if not args.servidor or not args.base:
        parser.error("Indica --servidor y --base, o configura DIAN_SQL_SERVER y DIAN_SQL_DATABASE.")
    if args.referencia and not args.referencia.is_file():
        parser.error("No existe --referencia.")
    return args


def cargar_motor(carpeta: Path):
    carpeta = carpeta.resolve()
    motor = carpeta / "procesamiento_facturas_contabilidad_match.py"
    limpieza = carpeta / "funciones_de_limpieza_base_datos_factura.py"
    if not motor.is_file() or not limpieza.is_file():
        raise FileNotFoundError("Faltan el script historico de match o su modulo de limpieza.")
    if str(carpeta) not in sys.path:
        sys.path.insert(0, str(carpeta))
    spec = importlib.util.spec_from_file_location("procesamiento_facturas_contabilidad_match", motor)
    if spec is None or spec.loader is None:
        raise RuntimeError("No fue posible importar el motor historico.")
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo, motor, limpieza


def conectar_sql(servidor: str, base: str, driver: str):
    import pyodbc
    from azure.identity import DefaultAzureCredential

    credencial = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    token = credencial.get_token("https://database.windows.net/.default").token
    token_bytes = token.encode("utf-16-le")
    token_odbc = struct.pack("=i", len(token_bytes)) + token_bytes
    cadena = (
        f"DRIVER={{{driver}}};SERVER=tcp:{servidor},1433;DATABASE={base};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        "ApplicationIntent=ReadOnly;"
    )
    return pyodbc.connect(
        cadena, attrs_before={1256: token_odbc}, autocommit=True
    )


def consultar(connection, query: str, parametros: tuple):
    import pandas as pd

    cursor = connection.cursor()
    try:
        cursor.execute(query, parametros)
        nombres = [col[0] for col in cursor.description]
        return pd.DataFrame.from_records(
            (tuple(fila) for fila in cursor.fetchall()), columns=nombres
        )
    finally:
        cursor.close()


def cargar_datos(connection, cliente_id: int, fuente: str, carga_dian_id: int | None):
    sql_facturas = FACTURAS_SQL
    parametros_facturas: tuple = (cliente_id,)
    if carga_dian_id is not None:
        sql_facturas += FILTRO_CARGA_SQL
        parametros_facturas += (cliente_id, carga_dian_id)
    sql_facturas += "ORDER BY v.[cufe];"
    facturas = consultar(connection, sql_facturas, parametros_facturas)
    movimientos = consultar(connection, MOVIMIENTOS_SQL, (cliente_id, fuente))
    return facturas, movimientos


def escribir_xlsx(df, ruta: Path) -> None:
    """Escribe texto como texto literal, incluso si empieza con '='."""
    import pandas as pd
    from openpyxl import Workbook
    from openpyxl.cell import WriteOnlyCell

    libro = Workbook(write_only=True)
    hoja = libro.create_sheet("Datos")
    hoja.append(list(df.columns))
    for fila in df.itertuples(index=False, name=None):
        celdas = []
        for valor in fila:
            if isinstance(valor, (tuple, list, dict)):
                valor = str(valor)
            elif valor is pd.NA or valor is pd.NaT or valor is None:
                valor = None
            elif not isinstance(valor, (str, bytes)) and pd.isna(valor):
                valor = None
            elif type(valor).__module__.startswith("numpy") and hasattr(valor, "item"):
                valor = valor.item()
            celda = WriteOnlyCell(hoja, value=valor)
            if isinstance(valor, str):
                celda.data_type = "s"
            celdas.append(celda)
        hoja.append(celdas)
    libro.save(ruta)


def validar_llaves(facturas) -> None:
    for columna in ("cufe", "llave_factura"):
        if columna not in facturas.columns:
            raise ValueError(f"El motor no produjo {columna}.")
        if facturas[columna].isna().any():
            raise ValueError(f"Hay facturas sin {columna}; no se puede medir cobertura confiable.")
        duplicadas = facturas[columna].duplicated(keep=False)
        if duplicadas.any():
            ejemplos = facturas.loc[duplicadas, columna].astype(str).head(3).tolist()
            raise ValueError(
                f"Hay {int(duplicadas.sum())} facturas con {columna} repetido "
                f"({ejemplos}). El motor historico agrupa por llave_factura; "
                "revise esta colision antes de aceptar la cobertura."
            )


def ejecutar_match(motor, facturas_sql, movimientos_sql):
    if facturas_sql.empty:
        raise ValueError("La vista no devolvio facturas procesadas en el alcance indicado.")
    if movimientos_sql.empty:
        raise ValueError("No hay movimientos contables para el cliente y la fuente indicados.")
    with tempfile.TemporaryDirectory(prefix="match_azure_") as temporal:
        ruta_facturas = Path(temporal) / "facturas.xlsx"
        ruta_movimientos = Path(temporal) / "movimientos.xlsx"
        escribir_xlsx(facturas_sql, ruta_facturas)
        escribir_xlsx(movimientos_sql, ruta_movimientos)
        facturas = motor.procesar_facturas(str(ruta_facturas), empresa="cpabaas")
        movimientos = motor.procesar_movimientos(
            str(ruta_movimientos), empresa="cpabaas",
            columnas_map=COLUMNAS_MOVIMIENTOS,
        )
    validar_llaves(facturas)
    movimientos_fc = motor.filtrar_movimientos_fc(movimientos)
    if movimientos_fc.empty:
        raise ValueError("No hay movimientos tipo FC despues de la normalizacion historica.")
    asientos = motor.agrupar_asientos_fc(movimientos_fc)
    candidatos = motor.generar_candidatos_match(facturas, asientos)
    matches = motor.resolver_match(candidatos)
    dataset = motor.construir_dataset_modelo(facturas, matches, asientos)
    if len(matches) != len(facturas) or len(dataset) != len(facturas):
        raise ValueError("El match no produjo una fila por factura; revise las llaves y el alcance.")
    return {
        "facturas": facturas,
        "movimientos": movimientos,
        "movimientos_fc": movimientos_fc,
        "asientos": asientos,
        "candidatos": candidatos,
        "matches": matches,
        "dataset": dataset,
    }


def _texto(valor) -> str:
    import pandas as pd

    if valor is None or pd.isna(valor):
        return ""
    return str(valor).strip()


def comparar_referencia(dataset, ruta_referencia: Path):
    import pandas as pd

    referencia = pd.read_excel(ruta_referencia, dtype="object")
    requeridas = {"llave_factura", "estado_match", "llave_asiento"}
    faltantes = requeridas - set(referencia.columns)
    if faltantes:
        raise ValueError(f"La referencia no tiene columnas: {sorted(faltantes)}")
    if referencia["llave_factura"].duplicated().any():
        raise ValueError("La referencia tiene llave_factura repetida.")
    actual = dataset[["llave_factura", "estado_match", "llave_asiento"]].copy()
    referencia = referencia[["llave_factura", "estado_match", "llave_asiento"]].copy()
    for tabla in (actual, referencia):
        for columna in ("llave_factura", "estado_match", "llave_asiento"):
            tabla[columna] = tabla[columna].map(_texto)
    comparacion = actual.merge(
        referencia, on="llave_factura", how="outer", suffixes=("_azure", "_referencia"),
        indicator=True, validate="one_to_one",
    )
    comunes = comparacion["_merge"].eq("both")
    comparacion["coincide_estado"] = comunes & comparacion["estado_match_azure"].eq(
        comparacion["estado_match_referencia"]
    )
    comparacion["coincide_asiento"] = comunes & comparacion["llave_asiento_azure"].eq(
        comparacion["llave_asiento_referencia"]
    )
    resumen = {
        "llaves_comunes": int(comunes.sum()),
        "solo_azure": int(comparacion["_merge"].eq("left_only").sum()),
        "solo_referencia": int(comparacion["_merge"].eq("right_only").sum()),
        "mismo_estado": int(comparacion["coincide_estado"].sum()),
        "mismo_asiento": int(comparacion["coincide_asiento"].sum()),
    }
    return comparacion, resumen


def _fecha_rango(serie) -> dict[str, str | None]:
    import pandas as pd

    fechas = pd.to_datetime(serie, errors="coerce").dropna()
    return {
        "desde": fechas.min().date().isoformat() if not fechas.empty else None,
        "hasta": fechas.max().date().isoformat() if not fechas.empty else None,
    }


def crear_resumen(resultados: dict, args: argparse.Namespace, motor: Path, limpieza: Path):
    facturas = resultados["facturas"]
    movimientos = resultados["movimientos"]
    matches = resultados["matches"]
    estados = {str(k): int(v) for k, v in matches["estado_match"].value_counts().items()}
    aceptados = sum(estados.get(estado, 0) for estado in ESTADOS_OK)
    return {
        "fecha_utc": datetime.now(timezone.utc).isoformat(),
        "alcance": {
            "servidor": args.servidor,
            "base": args.base,
            "cliente_id": args.cliente_id,
            "fuente_contable": args.fuente_contable,
            "carga_dian_id": args.carga_dian_id,
        },
        "version_scripts_sha256": {
            motor.name: hashlib.sha256(motor.read_bytes()).hexdigest(),
            limpieza.name: hashlib.sha256(limpieza.read_bytes()).hexdigest(),
        },
        "facturas_invoice_procesadas": len(facturas),
        "rango_facturas": _fecha_rango(facturas["fecha_emision"]),
        "movimientos_historicos": len(movimientos),
        "rango_movimientos": _fecha_rango(movimientos["fecha_mov"]),
        "movimientos_fc": len(resultados["movimientos_fc"]),
        "asientos_fc": len(resultados["asientos"]),
        "candidatos": len(resultados["candidatos"]),
        "estados_match": estados,
        "matches_aceptados": aceptados,
        "cobertura_match_pct": round(100 * aceptados / len(facturas), 2),
        "observacion": (
            "La cobertura no es precision. Compare solo periodos y fuentes equivalentes; "
            "este proceso no modifica reglas ni entrena el modelo."
        ),
    }


def main(argv: list[str] | None = None) -> int:
    args = argumentos(argv)
    motor, ruta_motor, ruta_limpieza = cargar_motor(args.scripts_historicos)
    connection = conectar_sql(args.servidor, args.base, args.driver)
    try:
        facturas_sql, movimientos_sql = cargar_datos(
            connection, args.cliente_id, args.fuente_contable, args.carga_dian_id
        )
    finally:
        connection.close()
    resultados = ejecutar_match(motor, facturas_sql, movimientos_sql)
    resumen = crear_resumen(resultados, args, ruta_motor, ruta_limpieza)
    comparacion = None
    if args.referencia:
        comparacion, resumen_comparacion = comparar_referencia(
            resultados["dataset"], args.referencia
        )
        resumen["comparacion_referencia"] = resumen_comparacion

    carpeta = args.salida / (
        "validacion_" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        + "_" + uuid.uuid4().hex[:8]
    )
    carpeta.mkdir(parents=True, exist_ok=False)
    columnas = [col for col in COLUMNAS_REPORTE if col in resultados["dataset"].columns]
    escribir_xlsx(resultados["dataset"][columnas], carpeta / "matches.xlsx")
    if comparacion is not None:
        escribir_xlsx(comparacion, carpeta / "comparacion_referencia.xlsx")
    (carpeta / "resumen.json").write_text(
        json.dumps(resumen, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({"salida": str(carpeta), **resumen}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
