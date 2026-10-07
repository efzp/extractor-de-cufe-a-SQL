from __future__ import annotations

import json
import uuid
from dataclasses import dataclass

from dian_ingestion.errors import SpreadsheetValidationError


@dataclass(frozen=True)
class AccountingQueuedLoad:
    correlation_id: str
    client_id: int
    source: str
    file_name: str
    blob_name: str
    preferred_sheet: str | None = None
    sharepoint_item_id: str | None = None
    sharepoint_url: str | None = None
    etag: str | None = None
    uploaded_by: str | None = None

    def to_json(self) -> str:
        return json.dumps(
            {
                "schemaVersion": 1,
                "correlationId": self.correlation_id,
                "clienteId": self.client_id,
                "fuenteContable": self.source,
                "nombreArchivo": self.file_name,
                "blobName": self.blob_name,
                "nombreHoja": self.preferred_sheet,
                "sharePointItemId": self.sharepoint_item_id,
                "sharePointUrl": self.sharepoint_url,
                "etag": self.etag,
                "cargadoPor": self.uploaded_by,
            },
            ensure_ascii=True,
            separators=(",", ":"),
        )

    @classmethod
    def from_json(cls, text: str) -> "AccountingQueuedLoad":
        try:
            data = json.loads(text)
            client_id = data["clienteId"]
            correlation_id = data["correlationId"]
            blob_name = data["blobName"]
            if (
                not isinstance(data, dict)
                or data.get("schemaVersion") != 1
                or type(client_id) is not int
                or client_id <= 0
                or not isinstance(correlation_id, str)
                or not isinstance(blob_name, str)
                or not blob_name.startswith(f"clientes/{client_id}/cargas/")
                or ".." in blob_name
            ):
                raise ValueError("Mensaje fuera de contrato")
            uuid.UUID(correlation_id)
            source = data["fuenteContable"]
            file_name = data["nombreArchivo"]
            if not isinstance(source, str) or not source.strip():
                raise ValueError("Fuente contable ausente")
            if not isinstance(file_name, str) or not file_name.lower().endswith(".xlsx"):
                raise ValueError("Nombre de archivo invalido")
            return cls(
                correlation_id=correlation_id,
                client_id=client_id,
                source=source,
                file_name=file_name,
                blob_name=blob_name,
                preferred_sheet=data.get("nombreHoja"),
                sharepoint_item_id=data.get("sharePointItemId"),
                sharepoint_url=data.get("sharePointUrl"),
                etag=data.get("etag"),
                uploaded_by=data.get("cargadoPor"),
            )
        except (TypeError, ValueError, KeyError, json.JSONDecodeError) as error:
            raise SpreadsheetValidationError("Mensaje de carga contable invalido.") from error


@dataclass(frozen=True)
class AccountingRow:
    row_number: int
    json_text: str


@dataclass(frozen=True)
class AccountingWorkbook:
    sheet_name: str
    rows: tuple[AccountingRow, ...]


@dataclass(frozen=True)
class AccountingSummary:
    correlation_id: str
    load_id: int
    status: str
    total_rows: int
    new_rows: int
    duplicate_rows: int
    conflict_rows: int
    rejected_rows: int
