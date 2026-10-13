"""Genera un snapshot ML desde Azure SQL usando el matching historico fijado.

El motor se ejecuta con el mismo contrato XLSX usado por el adaptador de
validacion. El procedimiento SQL decide si la version ya existe y publica las
filas en una sola transaccion.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import struct
import sys
import tempfile
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal
from functools import lru_cache
from pathlib import Path
from typing import Any

from .config import DatasetSettings
from .message import DatasetMessage


ROOT = Path(__file__).resolve().parent
LEGACY = ROOT / "legacy"
ENGINE = LEGACY / "procesamiento_facturas_contabilidad_match.py"
CLEANING = LEGACY / "funciones_de_limpieza_base_datos_factura.py"

INVOICES_SQL = """
SELECT v.*
FROM [ml].[vw_FacturaOrigenMlV1] AS v
WHERE v.[ClienteID] = ?
ORDER BY v.[DocumentoXmlID];
"""

# Mismo mapeo del adaptador de validacion (run_pipeline.py historico).
MOVEMENTS_SQL = """
SELECT
    [Fecha] AS [FECHA], [TipoDoc] AS [TIPODOC], [NumDoc] AS [NUMDOC],
    [Cuenta] AS [CUENTA], [NomCuenta] AS [NOM_CUENTA],
    [IdentidadTercero] AS [IDENTIDADTERCERO], [NombreTercero] AS [NOMBRETERCERO],
    [Concepto] AS [CONCEPTO], [Centro] AS [CENTRO], [CC] AS [C_C],
    [CodigoUsuario] AS [CODIGO_USUARIO], [DocFuente] AS [DOC_FUENTE],
    [NomCentro] AS [NOM_CENTRO], [Debito] AS [DEBITO], [Credito] AS [CREDITO]
FROM [contabilidad].[MovimientoHistorico]
WHERE [ClienteID] = ? AND [FuenteContable] = ?
ORDER BY [Fecha], [MovimientoID];
"""

MOVEMENT_COLUMNS = {
    "fecha_mov": "FECHA", "tipo_doc": "TIPODOC", "numero_doc": "NUMDOC",
    "cuenta": "CUENTA", "nombre_cuenta": "NOM_CUENTA",
    "identidad": "IDENTIDADTERCERO", "nombre_tercero": "NOMBRETERCERO",
    "concepto": "CONCEPTO", "codigo_centro_costo": "CENTRO",
    "centro_costo": "C_C", "usuario": "CODIGO_USUARIO",
    "numero_movil": "DOC_FUENTE", "nombre_centro_costo": "NOM_CENTRO",
    "debito": "DEBITO", "credito": "CREDITO",
}

FEATURES = (
    "nit_proveedor_norm", "ciudad_proveedor_modelo",
    "tax_level_proveedor_limpio", "tax_scheme_id_limpio",
    "tax_scheme_nombre_limpio", "codigo_industria_proveedor_limpio",
    "fecha_emision", "payable_amount", "descuento_total", "recargo_total",
    "tiene_iva", "tiene_inc", "flag_descuento", "flag_recargo",
    "flag_umbral_rf_servicios", "flag_umbral_reteica_bogota_servicios",
    "flag_umbral_reteica_bogota_compras",
    "flag_diferencia_payable_tax_inclusive",
    "standard_item_identification_limpio", "target_plantilla_cuentas",
)
STATES_OK = frozenset(("OK_UNICO", "OK_TEXTO", "OK_VALOR"))
BOOL_FEATURES = frozenset((
    "tiene_iva", "tiene_inc", "flag_descuento", "flag_recargo",
    "flag_umbral_rf_servicios", "flag_umbral_reteica_bogota_servicios",
    "flag_umbral_reteica_bogota_compras", "flag_diferencia_payable_tax_inclusive",
))


@dataclass(frozen=True)
class DatasetResult:
    correlation_id: str
    dataset_version_id: int | None
    result: str
    invoices: int
    movements: int
    accepted: int
    code_hash: str
    invoices_hash: str
    movements_hash: str


def enqueue(message: DatasetMessage, settings: DatasetSettings | None = None) -> None:
    from azure.identity import DefaultAzureCredential
    from azure.storage.queue import QueueClient

    settings = settings or DatasetSettings.from_environment()
    queue = QueueClient(
        account_url=f"https://{settings.storage_account}.queue.core.windows.net",
        queue_name=settings.queue_name,
        credential=DefaultAzureCredential(exclude_interactive_browser_credential=True),
    )
    queue.send_message(message.to_json())


def connect_sql(settings: DatasetSettings):
    import pyodbc
    from azure.identity import DefaultAzureCredential

    token = DefaultAzureCredential(
        exclude_interactive_browser_credential=True
    ).get_token("https://database.windows.net/.default").token
    token_bytes = token.encode("utf-16-le")
    token_struct = struct.pack("=i", len(token_bytes)) + token_bytes
    connection_string = (
        f"DRIVER={{{settings.sql_driver}}};"
        f"SERVER=tcp:{settings.sql_server},1433;"
        f"DATABASE={settings.sql_database};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
    )
    return pyodbc.connect(
        connection_string, attrs_before={1256: token_struct}, autocommit=True
    )


def query_frame(connection, sql: str, parameters: tuple):
    import pandas as pd

    cursor = connection.cursor()
    try:
        cursor.execute(sql, parameters)
        names = [column[0] for column in cursor.description]
        return pd.DataFrame.from_records(
            (tuple(row) for row in cursor.fetchall()), columns=names
        )
    finally:
        cursor.close()


@lru_cache(maxsize=1)
def load_engine():
    if not ENGINE.is_file() or not CLEANING.is_file():
        raise RuntimeError("Falta el motor historico empaquetado para el matching.")
    if str(LEGACY) not in sys.path:
        sys.path.insert(0, str(LEGACY))
    spec = importlib.util.spec_from_file_location("ml_dataset_matching_v1", ENGINE)
    if spec is None or spec.loader is None:
        raise RuntimeError("No fue posible cargar el motor historico.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if tuple(module.COLUMNAS_MODELO_AUTOG) != FEATURES:
        raise RuntimeError("El contrato ML no coincide con las columnas del motor.")
    return module


def _safe(value: Any) -> Any:
    import pandas as pd

    if value is None:
        return None
    if isinstance(value, (tuple, list)):
        return [_safe(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _safe(item) for key, item in value.items()}
    if isinstance(value, (datetime, date, pd.Timestamp)):
        return None if pd.isna(value) else value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, (bool, str, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if pd.isna(value):
        return None
    if hasattr(value, "item"):
        return _safe(value.item())
    raise TypeError(f"Tipo no serializable para el dataset: {type(value).__name__}")


def _canonical_json(records: list[dict[str, Any]]) -> str:
    return json.dumps(
        _safe(records), ensure_ascii=False, sort_keys=True,
        separators=(",", ":"), allow_nan=False,
    )


def _frame_hash(frame) -> str:
    return hashlib.sha256(
        _canonical_json(frame.to_dict(orient="records")).encode("utf-8")
    ).hexdigest()


def _code_hash() -> str:
    import numpy
    import openpyxl
    import pandas

    digest = hashlib.sha256()
    for path in (ENGINE, CLEANING, Path(__file__)):
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    runtime = {
        "python": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "numpy": numpy.__version__,
        "pandas": pandas.__version__,
        "openpyxl": openpyxl.__version__,
    }
    digest.update(json.dumps(runtime, sort_keys=True).encode("ascii"))
    return digest.hexdigest()


def _write_xlsx(frame, path: Path) -> None:
    """Conserva el contrato XLSX del adaptador validado, incluso texto =..."""
    import pandas as pd
    from openpyxl import Workbook
    from openpyxl.cell import WriteOnlyCell

    workbook = Workbook(write_only=True)
    sheet = workbook.create_sheet("Datos")
    sheet.append(list(frame.columns))
    for values in frame.itertuples(index=False, name=None):
        cells = []
        for value in values:
            if isinstance(value, (tuple, list, dict)):
                value = str(value)
            elif isinstance(value, Decimal):
                value = format(value, "f")
            elif value is pd.NA or value is pd.NaT or value is None:
                value = None
            elif not isinstance(value, (str, bytes)) and pd.isna(value):
                value = None
            elif type(value).__module__.startswith("numpy") and hasattr(value, "item"):
                value = value.item()
            cell = WriteOnlyCell(sheet, value=value)
            if isinstance(value, str):
                cell.data_type = "s"
            cells.append(cell)
        sheet.append(cells)
    workbook.save(path)


def _run_match(engine, invoices, movements):
    if invoices.empty:
        raise ValueError("No hay facturas Invoice procesadas para el cliente.")
    if movements.empty:
        raise ValueError("No hay movimientos para el cliente y la fuente indicados.")
    if invoices["cufe"].isna().any() or invoices["cufe"].duplicated().any():
        raise ValueError("La fuente XML contiene CUFE nulos o repetidos.")
    with tempfile.TemporaryDirectory(prefix="ml_dataset_") as directory:
        invoice_path = Path(directory) / "facturas.xlsx"
        movement_path = Path(directory) / "movimientos.xlsx"
        _write_xlsx(invoices, invoice_path)
        _write_xlsx(movements, movement_path)
        normalized_invoices = engine.procesar_facturas(
            str(invoice_path), empresa="cpabaas"
        )
        normalized_movements = engine.procesar_movimientos(
            str(movement_path), empresa="cpabaas", columnas_map=MOVEMENT_COLUMNS
        )
    if normalized_invoices["llave_factura"].isna().any() or normalized_invoices[
        "llave_factura"
    ].duplicated().any():
        raise ValueError("El motor genero llaves de factura nulas o repetidas.")
    movements_fc = engine.filtrar_movimientos_fc(normalized_movements)
    if movements_fc.empty:
        raise ValueError("No hay movimientos FC despues de la normalizacion.")
    entries = engine.agrupar_asientos_fc(movements_fc)
    candidates = engine.generar_candidatos_match(normalized_invoices, entries)
    matches = engine.resolver_match(candidates)
    dataset = engine.construir_dataset_modelo(normalized_invoices, matches, entries)
    if len(dataset) != len(invoices) or len(matches) != len(invoices):
        raise ValueError("El matching no produjo una fila por factura.")
    return dataset


def _training_rows(dataset, invoices) -> list[dict[str, Any]]:
    missing = (set(FEATURES) | {"cufe", "estado_match", "llave_asiento"}) - set(dataset.columns)
    if missing:
        raise ValueError(f"El motor no produjo columnas requeridas: {sorted(missing)}")
    sources = {
        str(row.cufe).lower(): (int(row.DocumentoXmlID), int(row.VersionExtractor))
        for row in invoices[["cufe", "DocumentoXmlID", "VersionExtractor"]].itertuples(index=False)
    }
    selected = dataset[
        dataset["estado_match"].isin(STATES_OK)
        & dataset["target_plantilla_cuentas"].notna()
    ].copy()
    rows = []
    for record in selected.to_dict(orient="records"):
        cufe = str(record["cufe"]).lower()
        if cufe not in sources:
            raise ValueError("Un match aceptado no tiene XML de origen.")
        xml_id, version = sources[cufe]
        label = str(record["target_plantilla_cuentas"])
        if not label.strip():
            raise ValueError("Un match aceptado tiene etiqueta vacia.")
        if _safe(record["llave_asiento"]) is None or not str(record["llave_asiento"]).strip():
            raise ValueError("Un match aceptado no tiene llave de asiento.")
        row = {
            "documento_xml_id": xml_id,
            "version_extractor": version,
            "cufe": cufe,
            "estado_match": str(record["estado_match"]),
            "llave_asiento": str(record["llave_asiento"]),
        }
        for feature in FEATURES:
            value = label if feature == "target_plantilla_cuentas" else _safe(record[feature])
            if feature in BOOL_FEATURES and value is not None:
                value = int(bool(value))
            if feature == "fecha_emision" and value is None:
                raise ValueError("Un match aceptado no tiene fecha de emision.")
            row[feature] = value
        rows.append(row)
    rows.sort(key=lambda row: row["documento_xml_id"])
    if len({row["documento_xml_id"] for row in rows}) != len(rows):
        raise ValueError("Hay DocumentoXmlID repetidos en el dataset.")
    if len({row["cufe"] for row in rows}) != len(rows):
        raise ValueError("Hay CUFE repetidos en el dataset.")
    return rows


def _publish(connection, message: DatasetMessage, code_hash: str,
             invoices_hash: str, movements_hash: str, invoices_count: int,
             rows: list[dict[str, Any]]) -> dict[str, Any]:
    cursor = connection.cursor()
    try:
        cursor.execute(
            "EXEC [ml].[sp_PublicarDatasetEntrenamientoV1] "
            "@ClienteID = ?, @FuenteContable = ?, @HashCodigoSha256 = ?, "
            "@HashFacturasSha256 = ?, @HashMovimientosSha256 = ?, "
            "@TotalFacturasOrigen = ?, @FilasJson = ?;",
            message.client_id, message.accounting_source, code_hash,
            invoices_hash, movements_hash, invoices_count,
            _canonical_json(rows),
        )
        result = cursor.fetchone()
        if result is None or cursor.description is None:
            raise RuntimeError("El procedimiento ML no devolvio resultado.")
        return dict(zip((column[0] for column in cursor.description), result))
    finally:
        cursor.close()


def generate_dataset(message_text: str, *, settings: DatasetSettings | None = None,
                     connector=connect_sql) -> DatasetResult:
    message = DatasetMessage.from_json(message_text)
    settings = settings or DatasetSettings.from_environment()
    engine = load_engine()
    connection = connector(settings)
    try:
        invoices = query_frame(connection, INVOICES_SQL, (message.client_id,))
        movements = query_frame(
            connection, MOVEMENTS_SQL, (message.client_id, message.accounting_source)
        )
        code_hash = _code_hash()
        invoices_hash = _frame_hash(invoices)
        movements_hash = _frame_hash(movements)
        dataset = _run_match(engine, invoices, movements)
        rows = _training_rows(dataset, invoices)
        if not rows:
            return DatasetResult(
                message.correlation_id, None, "SIN_ETIQUETAS", len(invoices),
                len(movements), 0, code_hash, invoices_hash, movements_hash,
            )
        published = _publish(
            connection, message, code_hash, invoices_hash, movements_hash,
            len(invoices), rows,
        )
        return DatasetResult(
            message.correlation_id, int(published["DatasetVersionID"]),
            str(published["Resultado"]), len(invoices), len(movements),
            len(rows), code_hash, invoices_hash, movements_hash,
        )
    finally:
        connection.close()
