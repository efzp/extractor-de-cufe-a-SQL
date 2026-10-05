from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any

from .errors import SpreadsheetValidationError


@dataclass(frozen=True)
class QueuedLoad:
    schema_version: int
    correlation_id: str
    client_id: int
    file_name: str
    blob_name: str
    sharepoint_item_id: str | None = None
    sharepoint_url: str | None = None
    etag: str | None = None
    preferred_table_name: str | None = None
    uploaded_by: str | None = None

    def to_json(self) -> str:
        payload = {
            "schemaVersion": self.schema_version,
            "correlationId": self.correlation_id,
            "clientId": self.client_id,
            "fileName": self.file_name,
            "blobName": self.blob_name,
            "sharePointItemId": self.sharepoint_item_id,
            "sharePointUrl": self.sharepoint_url,
            "eTag": self.etag,
            "preferredTableName": self.preferred_table_name,
            "uploadedBy": self.uploaded_by,
        }
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))

    @classmethod
    def from_json(cls, value: str) -> "QueuedLoad":
        try:
            payload = json.loads(value)
            message = cls(
                schema_version=int(payload["schemaVersion"]),
                correlation_id=str(payload["correlationId"]),
                client_id=int(payload["clientId"]),
                file_name=str(payload["fileName"]),
                blob_name=str(payload["blobName"]),
                sharepoint_item_id=_optional_string(payload.get("sharePointItemId")),
                sharepoint_url=_optional_string(payload.get("sharePointUrl")),
                etag=_optional_string(payload.get("eTag")),
                preferred_table_name=_optional_string(payload.get("preferredTableName")),
                uploaded_by=_optional_string(payload.get("uploadedBy")),
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise SpreadsheetValidationError(
                "El mensaje de carga no tiene el formato esperado."
            ) from error

        if message.schema_version != 1:
            raise SpreadsheetValidationError(
                "La versión del mensaje de carga no es compatible."
            )
        if message.client_id <= 0:
            raise SpreadsheetValidationError("El ClienteID debe ser positivo.")
        if not message.correlation_id or not message.file_name or not message.blob_name:
            raise SpreadsheetValidationError(
                "El mensaje no contiene todos los identificadores obligatorios."
            )
        return message


@dataclass(frozen=True)
class NormalizedDocumentRow:
    row_number: int
    document_key: str | None
    key_type: str
    values: dict[str, Any]
    row_hash: str
    content_hash: str
    original_json: str


@dataclass(frozen=True)
class WorkbookData:
    sheet_name: str
    table_name: str
    rows: tuple[NormalizedDocumentRow, ...]


@dataclass(frozen=True)
class IngestionSummary:
    correlation_id: str
    load_id: int
    status: str
    total_rows: int
    valid_rows: int
    duplicate_rows: int
    revision_rows: int
    error_rows: int
    queued_documents: int
    ignored_rows: int = 0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _optional_string(value: Any) -> str | None:
    if value is None:
        return None
    normalized = str(value).strip()
    return normalized or None
