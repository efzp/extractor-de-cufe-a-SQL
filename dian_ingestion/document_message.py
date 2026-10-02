from __future__ import annotations

import json
import re
from dataclasses import dataclass


class DocumentMessageError(ValueError):
    """El mensaje de documentos-pendientes no cumple el contrato."""


@dataclass(frozen=True)
class QueuedDocument:
    correlation_id: str
    client_id: int
    load_id: int
    document_id: int
    version_id: int
    key_type: str
    document_key: str

    @classmethod
    def from_json(cls, value: str) -> "QueuedDocument":
        try:
            data = json.loads(value)
            if not isinstance(data, dict) or data.get("schemaVersion") != 1:
                raise DocumentMessageError("Version de mensaje no compatible.")
            for name in (
                "clienteId", "cargaArchivoId", "documentoId", "documentoVersionId"
            ):
                if type(data.get(name)) is not int or data[name] <= 0:
                    raise DocumentMessageError(f"{name} debe ser un entero positivo.")
            correlation = data.get("correlationId")
            key_type = data.get("tipoClave")
            key = data.get("claveDocumento")
            if not isinstance(correlation, str) or not correlation.strip():
                raise DocumentMessageError("Falta correlationId.")
            if key_type not in ("CUFE", "CUDE"):
                raise DocumentMessageError("tipoClave no valido.")
            if not isinstance(key, str) or not re.fullmatch(r"[0-9a-fA-F]{96}", key):
                raise DocumentMessageError("claveDocumento no valida.")
            return cls(
                correlation_id=correlation.strip(),
                client_id=data["clienteId"],
                load_id=data["cargaArchivoId"],
                document_id=data["documentoId"],
                version_id=data["documentoVersionId"],
                key_type=key_type,
                document_key=key.lower(),
            )
        except (TypeError, ValueError, json.JSONDecodeError) as error:
            if isinstance(error, DocumentMessageError):
                raise
            raise DocumentMessageError("El mensaje no es JSON valido.") from error

    def to_payload(self) -> dict:
        return {
            "schemaVersion": 1,
            "correlationId": self.correlation_id,
            "clienteId": self.client_id,
            "cargaArchivoId": self.load_id,
            "documentoId": self.document_id,
            "documentoVersionId": self.version_id,
            "tipoClave": self.key_type,
            "claveDocumento": self.document_key,
        }
