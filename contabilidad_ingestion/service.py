from __future__ import annotations

import hashlib
import uuid
import zipfile
from datetime import datetime, timezone
from io import BytesIO
from typing import Callable

from dian_ingestion.errors import SpreadsheetValidationError
from dian_ingestion.storage import StorageGateway

from .config import AccountingSettings
from .models import AccountingQueuedLoad, AccountingSummary
from .reader import read_accounting_workbook
from .repository import AccountingSqlRepository


def _optional(value: str | None, maximum: int) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise SpreadsheetValidationError("Metadato contable invalido.")
    result = value.strip() or None
    if result is not None and len(result) > maximum:
        raise SpreadsheetValidationError("Metadato contable demasiado largo.")
    return result


def accept_accounting_upload(
    client_id: int,
    source: str,
    file_name: str,
    content: bytes,
    *,
    preferred_sheet: str | None = None,
    sharepoint_item_id: str | None = None,
    sharepoint_url: str | None = None,
    etag: str | None = None,
    uploaded_by: str | None = None,
    settings: AccountingSettings | None = None,
    storage: StorageGateway | None = None,
) -> AccountingQueuedLoad:
    settings = settings or AccountingSettings.from_environment()
    if client_id <= 0:
        raise SpreadsheetValidationError("ClienteID debe ser positivo.")
    source = _optional(source, 80)
    file_name = _optional(file_name, 260)
    if source is None:
        raise SpreadsheetValidationError("FuenteContable es obligatoria.")
    if (
        file_name is None
        or not file_name.lower().endswith(".xlsx")
        or "/" in file_name
        or "\\" in file_name
        or any(ord(c) < 32 for c in file_name)
    ):
        raise SpreadsheetValidationError("NombreArchivo debe ser un nombre XLSX valido.")
    if not isinstance(content, bytes) or not content or len(content) > settings.max_upload_bytes:
        raise SpreadsheetValidationError("El XLSX esta vacio o supera el limite permitido.")
    try:
        with zipfile.ZipFile(BytesIO(content)) as archive:
            names = set(archive.namelist())
            if "xl/workbook.xml" not in names:
                raise SpreadsheetValidationError("El archivo no es un XLSX valido.")
            if sum(info.file_size for info in archive.infolist()) > 200 * 1024 * 1024:
                raise SpreadsheetValidationError("El XLSX descomprimido excede el limite.")
    except zipfile.BadZipFile as error:
        raise SpreadsheetValidationError("El archivo no es un XLSX valido.") from error

    correlation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    blob_name = f"clientes/{client_id}/cargas/{now:%Y/%m}/{correlation_id}.xlsx"
    message = AccountingQueuedLoad(
        correlation_id=correlation_id,
        client_id=client_id,
        source=source,
        file_name=file_name,
        blob_name=blob_name,
        preferred_sheet=_optional(preferred_sheet, 128),
        sharepoint_item_id=_optional(sharepoint_item_id, 150),
        sharepoint_url=_optional(sharepoint_url, 1000),
        etag=_optional(etag, 200),
        uploaded_by=_optional(uploaded_by, 256),
    )
    storage = storage or StorageGateway(settings)
    storage.upload_load(blob_name, content)
    try:
        storage.enqueue_load(message.to_json())
    except Exception:
        storage.delete_load(blob_name)
        raise
    return message


def process_accounting_load(
    message_text: str,
    *,
    settings: AccountingSettings | None = None,
    storage: StorageGateway | None = None,
    repository_factory: Callable[[], AccountingSqlRepository] | None = None,
) -> AccountingSummary:
    message = AccountingQueuedLoad.from_json(message_text)
    settings = settings or AccountingSettings.from_environment()
    storage = storage or StorageGateway(settings)
    repository_factory = repository_factory or (
        lambda: AccountingSqlRepository(settings)
    )

    content = storage.download_load(message.blob_name)
    if len(content) > settings.max_upload_bytes:
        raise SpreadsheetValidationError("El XLSX supera el limite permitido.")
    workbook = read_accounting_workbook(
        content, message.preferred_sheet, settings.max_rows
    )
    file_hash = hashlib.sha256(content).hexdigest()
    blob_uri = (
        f"{settings.storage_account_url}/{settings.load_container}/"
        f"{message.blob_name}"
    )
    with repository_factory() as repository:
        start = repository.start_load(
            message, file_hash, workbook.sheet_name, blob_uri, len(content)
        )
        load_id = int(start["CargaArchivoID"])
        status = str(start["Estado"])
        # PROCESANDO is resumable: SQL makes each (carga, fila) idempotent.
        if status not in ("RECIBIDA", "PROCESANDO"):
            return AccountingSummary(
                correlation_id=message.correlation_id,
                load_id=load_id,
                status=status,
                total_rows=0,
                new_rows=0,
                duplicate_rows=0,
                conflict_rows=0,
                rejected_rows=0,
            )
        for row in workbook.rows:
            repository.register_movement(load_id, row)
        final = repository.finish_load(load_id, len(workbook.rows))

    return AccountingSummary(
        correlation_id=message.correlation_id,
        load_id=load_id,
        status=str(final["Estado"]),
        total_rows=int(final["TotalFilas"] or 0),
        new_rows=int(final["FilasNuevas"] or 0),
        duplicate_rows=int(final["FilasDuplicadas"] or 0),
        conflict_rows=int(final["FilasConflicto"] or 0),
        rejected_rows=int(final["FilasRechazadas"] or 0),
    )
