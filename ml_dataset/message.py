from __future__ import annotations

import json
import uuid
from dataclasses import dataclass


@dataclass(frozen=True)
class DatasetMessage:
    correlation_id: str
    client_id: int
    accounting_source: str

    @classmethod
    def create(cls, client_id: int, accounting_source: str) -> "DatasetMessage":
        if type(client_id) is not int or client_id <= 0:
            raise ValueError("ClienteID debe ser un entero positivo.")
        if not isinstance(accounting_source, str):
            raise ValueError("FuenteContable es obligatoria.")
        source = accounting_source.strip()
        if not source or len(source) > 80:
            raise ValueError("FuenteContable debe tener entre 1 y 80 caracteres.")
        return cls(str(uuid.uuid4()), client_id, source)

    @classmethod
    def from_json(cls, raw: str) -> "DatasetMessage":
        payload = json.loads(raw)
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
            raise ValueError("Mensaje ML no compatible.")
        message = cls.create(payload.get("clienteId"), payload.get("fuenteContable"))
        correlation_id = payload.get("correlationId")
        try:
            normalized = str(uuid.UUID(correlation_id))
        except (ValueError, TypeError, AttributeError) as error:
            raise ValueError("CorrelationID no valido.") from error
        return cls(normalized, message.client_id, message.accounting_source)

    def to_json(self) -> str:
        return json.dumps(
            {
                "schemaVersion": 1,
                "correlationId": self.correlation_id,
                "clienteId": self.client_id,
                "fuenteContable": self.accounting_source,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
