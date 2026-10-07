from __future__ import annotations

import os
from dataclasses import dataclass

from dian_ingestion.errors import IngestionConfigurationError


@dataclass(frozen=True)
class AccountingSettings:
    storage_account: str
    load_container: str
    load_queue: str
    sql_server: str
    sql_database: str
    sql_driver: str
    max_upload_bytes: int
    max_rows: int

    @property
    def storage_account_url(self) -> str:
        return f"https://{self.storage_account}.blob.core.windows.net"

    @property
    def queue_account_url(self) -> str:
        return f"https://{self.storage_account}.queue.core.windows.net"

    @classmethod
    def from_environment(cls) -> "AccountingSettings":
        def required(name: str) -> str:
            value = os.environ.get(name, "").strip()
            if not value or value.startswith("CONFIGURE_"):
                raise IngestionConfigurationError(f"Falta configurar {name}.")
            return value

        def positive(name: str, default: str) -> int:
            try:
                value = int(os.environ.get(name, default))
            except ValueError as error:
                raise IngestionConfigurationError(f"{name} debe ser entero.") from error
            if value <= 0:
                raise IngestionConfigurationError(f"{name} debe ser positivo.")
            return value

        settings = cls(
            storage_account=required("DIAN_STORAGE_ACCOUNT"),
            load_container=os.environ.get(
                "CONTABILIDAD_LOAD_CONTAINER", "cargas-contabilidad"
            ).strip(),
            load_queue=os.environ.get(
                "CONTABILIDAD_LOAD_QUEUE_NAME", "contabilidad-cargas-pendientes"
            ).strip(),
            sql_server=required("DIAN_SQL_SERVER"),
            sql_database=required("DIAN_SQL_DATABASE"),
            sql_driver=os.environ.get(
                "DIAN_SQL_DRIVER", "ODBC Driver 18 for SQL Server"
            ).strip(),
            max_upload_bytes=positive("CONTABILIDAD_MAX_UPLOAD_BYTES", "20971520"),
            max_rows=positive("CONTABILIDAD_MAX_ROWS", "50000"),
        )
        if not settings.load_container or not settings.load_queue or not settings.sql_driver:
            raise IngestionConfigurationError(
                "El contenedor, la cola y el controlador SQL son obligatorios."
            )
        return settings
