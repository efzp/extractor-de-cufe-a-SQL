from __future__ import annotations

import os
from dataclasses import dataclass

from .errors import IngestionConfigurationError


@dataclass(frozen=True)
class IngestionSettings:
    storage_account: str
    load_container: str
    load_queue: str
    document_queue: str
    sql_server: str
    sql_database: str
    sql_driver: str
    max_upload_bytes: int

    @property
    def storage_account_url(self) -> str:
        return f"https://{self.storage_account}.blob.core.windows.net"

    @property
    def queue_account_url(self) -> str:
        return f"https://{self.storage_account}.queue.core.windows.net"

    @classmethod
    def from_environment(cls) -> "IngestionSettings":
        settings = cls(
            storage_account=_required("DIAN_STORAGE_ACCOUNT"),
            load_container=os.environ.get(
                "DIAN_LOAD_CONTAINER", "cargas-dian"
            ).strip(),
            load_queue=os.environ.get(
                "DIAN_LOAD_QUEUE_NAME", "cargas-pendientes"
            ).strip(),
            document_queue=os.environ.get(
                "DIAN_QUEUE_NAME", "documentos-pendientes"
            ).strip(),
            sql_server=_required("DIAN_SQL_SERVER"),
            sql_database=_required("DIAN_SQL_DATABASE"),
            sql_driver=os.environ.get(
                "DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"
            ).strip(),
            max_upload_bytes=_positive_int("DIAN_MAX_UPLOAD_BYTES", "20971520"),
        )
        for name, value in (
            ("DIAN_LOAD_CONTAINER", settings.load_container),
            ("DIAN_LOAD_QUEUE_NAME", settings.load_queue),
            ("DIAN_QUEUE_NAME", settings.document_queue),
            ("DIAN_SQL_DRIVER", settings.sql_driver),
        ):
            if not value:
                raise IngestionConfigurationError(f"{name} no puede estar vacío.")
        return settings


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or value.startswith("CONFIGURE_"):
        raise IngestionConfigurationError(f"Falta configurar {name}.")
    return value


def _positive_int(name: str, default: str) -> int:
    try:
        value = int(os.environ.get(name, default))
    except ValueError as error:
        raise IngestionConfigurationError(f"{name} debe ser entero.") from error
    if value <= 0:
        raise IngestionConfigurationError(f"{name} debe ser positivo.")
    return value

