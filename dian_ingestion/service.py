from __future__ import annotations

import re
import uuid
from datetime import datetime, timezone
from typing import Callable

from .config import IngestionSettings
from .errors import SpreadsheetValidationError
from .excel_reader import read_dian_workbook
from .hashing import sha256_hex
from .models import IngestionSummary, QueuedLoad, WorkbookData
from .sql_repository import SqlRepository
from .storage import StorageGateway


def accept_upload(
    client_id: int,
    file_name: str,
    content: bytes,
    *,
    sharepoint_item_id: str | None = None,
    sharepoint_url: str | None = None,
    etag: str | None = None,
    preferred_table_name: str | None = None,
    uploaded_by: str | None = None,
    settings: IngestionSettings | None = None,
    storage: StorageGateway | None = None,
) -> QueuedLoad:
    settings = settings or IngestionSettings.from_environment()
    if client_id <= 0:
        raise SpreadsheetValidationError("El ClienteID debe ser positivo.")

    safe_file_name = _safe_file_name(file_name)
    if not safe_file_name.lower().endswith(".xlsx"):
        raise SpreadsheetValidationError("Solo se aceptan archivos XLSX.")
    if not content or not content.startswith(b"PK"):
        raise SpreadsheetValidationError("El contenido no corresponde a un XLSX.")
    if len(content) > settings.max_upload_bytes:
        raise SpreadsheetValidationError(
            "El archivo supera el tamaño máximo permitido."
        )

    correlation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    blob_name = (
        f"clientes/{client_id}/cargas/{now:%Y/%m}/"
        f"{correlation_id}-{safe_file_name}"
    )
    message = QueuedLoad(
        schema_version=1,
        correlation_id=correlation_id,
        client_id=client_id,
        file_name=safe_file_name,
        blob_name=blob_name,
        sharepoint_item_id=_optional(sharepoint_item_id),
        sharepoint_url=_optional(sharepoint_url),
        etag=_optional(etag),
        preferred_table_name=_optional(preferred_table_name),
        uploaded_by=_optional(uploaded_by),
    )

    storage = storage or StorageGateway(settings)
    storage.upload_load(blob_name, content)
    try:
        storage.enqueue_load(message.to_json())
    except Exception:
        storage.delete_load(blob_name)
        raise
    return message


def process_queued_load(
    message_text: str,
    *,
    settings: IngestionSettings | None = None,
    storage: StorageGateway | None = None,
    repository_factory: Callable[[], SqlRepository] | None = None,
    workbook_reader: Callable[[bytes, str | None], WorkbookData] = read_dian_workbook,
) -> IngestionSummary:
    message = QueuedLoad.from_json(message_text)
    settings = settings or IngestionSettings.from_environment()
    storage = storage or StorageGateway(settings)
    repository_factory = repository_factory or (lambda: SqlRepository(settings))

    content = storage.download_load(message.blob_name)
    workbook = workbook_reader(content, message.preferred_table_name)
    file_hash = sha256_hex(content)
    queued_documents = 0

    with repository_factory() as repository:
        start = repository.start_load(message, file_hash, workbook.table_name)
        load_id = int(start["CargaArchivoID"])
        load_status = str(start["Estado"])

        if load_status not in ("RECIBIDA", "PROCESANDO"):
            return IngestionSummary(
                correlation_id=message.correlation_id,
                load_id=load_id,
                status=load_status,
                total_rows=0,
                valid_rows=0,
                duplicate_rows=0,
                revision_rows=0,
                error_rows=0,
                queued_documents=0,
            )

        for row in workbook.rows:
            result = repository.register_document(load_id, row)
            if _must_enqueue_document(result):
                storage.enqueue_document(
                    {
                        "schemaVersion": 1,
                        "correlationId": message.correlation_id,
                        "clienteId": message.client_id,
                        "cargaArchivoId": load_id,
                        "documentoId": int(result["DocumentoID"]),
                        "documentoVersionId": int(result["DocumentoVersionID"]),
                        "tipoClave": row.key_type,
                        "claveDocumento": row.document_key,
                    }
                )
                queued_documents += 1

        final = repository.finish_load(load_id, len(workbook.rows))

    return IngestionSummary(
        correlation_id=message.correlation_id,
        load_id=load_id,
        status=str(final["Estado"]),
        total_rows=int(final["TotalFilas"] or 0),
        valid_rows=int(final["FilasValidas"] or 0),
        duplicate_rows=int(final["FilasDuplicadas"] or 0),
        revision_rows=int(final["FilasRevision"] or 0),
        error_rows=int(final["FilasError"] or 0),
        queued_documents=queued_documents,
    )


def _must_enqueue_document(result: dict) -> bool:
    return (
        result.get("DocumentoID") is not None
        and result.get("DocumentoVersionID") is not None
        and str(result.get("Resultado")) == "NUEVO"
        and str(result.get("EstadoProceso")) == "PENDIENTE_DESCARGA"
    )


def _safe_file_name(value: str) -> str:
    if not isinstance(value, str):
        raise SpreadsheetValidationError("El nombre del archivo es obligatorio.")
    name = re.split(r"[/\\]", value.strip())[-1]
    name = re.sub(r"[^0-9A-Za-zÁÉÍÓÚÜÑáéíóúüñ._ -]+", "_", name)
    if not name or len(name) > 180:
        raise SpreadsheetValidationError("El nombre del archivo no es válido.")
    return name


def _optional(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = str(value).strip()
    return normalized or None

