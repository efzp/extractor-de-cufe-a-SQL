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
    xml_container: str = "xml-dian"
    max_document_attempts: int = 5
    claim_timeout_seconds: int = 540
    document_retry_delay_seconds: int = 60
    max_xml_bytes: int = 20 * 1024 * 1024

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
            xml_container=os.environ.get("DIAN_XML_CONTAINER", "xml-dian").strip(),
            max_document_attempts=_positive_int("DIAN_MAX_DOCUMENT_ATTEMPTS", "5"),
            claim_timeout_seconds=_positive_int("DIAN_CLAIM_TIMEOUT_SECONDS", "540"),
            document_retry_delay_seconds=_positive_int(
                "DIAN_DOCUMENT_RETRY_DELAY_SECONDS", "60"
            ),
            max_xml_bytes=_positive_int("DIAN_MAX_XML_BYTES", "20971520"),
        )
        for name, value in (
            ("DIAN_LOAD_CONTAINER", settings.load_container),
            ("DIAN_LOAD_QUEUE_NAME", settings.load_queue),
            ("DIAN_QUEUE_NAME", settings.document_queue),
            ("DIAN_SQL_DRIVER", settings.sql_driver),
            ("DIAN_XML_CONTAINER", settings.xml_container),
        ):
            if not value:
                raise IngestionConfigurationError(f"{name} no puede estar vacío.")
        if settings.max_document_attempts > 32767:
            raise IngestionConfigurationError(
                "DIAN_MAX_DOCUMENT_ATTEMPTS supera smallint."
            )
        if settings.claim_timeout_seconds > 86400:
            raise IngestionConfigurationError(
                "DIAN_CLAIM_TIMEOUT_SECONDS supera 86400."
            )
        if settings.document_retry_delay_seconds > 604800:
            raise IngestionConfigurationError(
                "DIAN_DOCUMENT_RETRY_DELAY_SECONDS supera 7 dias."
            )
        if settings.xml_container != "xml-dian":
            raise IngestionConfigurationError(
                "DIAN_XML_CONTAINER debe ser xml-dian por contrato SQL."
            )
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
