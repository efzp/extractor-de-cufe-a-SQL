from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Callable

from lxml import etree

from dian.errors import (
    DianConfigurationError,
    DianDocumentNotFoundError,
    DianSoapFaultError,
)
from dian.service import fetch_dian_document

from .config import IngestionSettings
from .document_message import QueuedDocument
from .sql_repository import SqlRepository
from .storage import StorageGateway


@dataclass(frozen=True)
class DocumentProcessingSummary:
    document_id: int
    consultation_id: int | None
    result: str
    retry_queued: bool = False


class UnsupportedXmlTypeError(ValueError):
    """El XML obtenido no corresponde a un documento útil para el proceso."""


def process_queued_document(
    message_text: str,
    *,
    settings: IngestionSettings | None = None,
    storage: StorageGateway | None = None,
    repository_factory: Callable[[], SqlRepository] | None = None,
    fetch_xml: Callable | None = None,
) -> DocumentProcessingSummary:
    message = QueuedDocument.from_json(message_text)
    settings = settings or IngestionSettings.from_environment()
    storage = storage or StorageGateway(settings)
    repository_factory = repository_factory or (lambda: SqlRepository(settings))
    fetch_xml = fetch_xml or fetch_dian_document

    with repository_factory() as repository:
        claim = repository.start_document(
            message, settings.max_document_attempts, settings.claim_timeout_seconds
        )
        result = str(claim["Resultado"])
        consultation_id = claim["ConsultaDianID"]
        if result == "CONSULTA_EN_PROGRESO":
            storage.enqueue_document(
                message.to_payload(), delay_seconds=settings.claim_timeout_seconds
            )
            return DocumentProcessingSummary(
                message.document_id, consultation_id, result, retry_queued=True
            )
        if result in ("XML_YA_REGISTRADO", "ESTADO_NO_ELEGIBLE", "MAXIMO_INTENTOS"):
            return DocumentProcessingSummary(message.document_id, consultation_id, result)
        if result != "CONSULTA_INICIADA" or not claim["DebeConsultar"]:
            raise RuntimeError("Resultado de reclamo DIAN no reconocido.")
        if consultation_id is None:
            raise RuntimeError("La consulta iniciada no tiene identificador.")

        started = time.perf_counter()
        dian_code = None
        error_type = None
        try:
            document = fetch_xml(message.document_key)
            content = document.xml_bytes
            if not content or len(content) > settings.max_xml_bytes:
                raise ValueError("Tamano del XML DIAN no valido.")
            root = etree.fromstring(
                content, parser=etree.XMLParser(resolve_entities=False, no_network=True)
            )
            xml_type = etree.QName(root).localname[:80]
            if xml_type.casefold() == "applicationresponse":
                raise UnsupportedXmlTypeError(
                    "ApplicationResponse no se almacena ni registra como XML útil."
                )
            uri, digest = storage.upload_document(
                message.client_id, message.document_id, content
            )
            registered = repository.register_xml(
                message.document_id, consultation_id, uri, digest,
                len(content), xml_type,
            )
            if registered["Resultado"] not in ("XML_REGISTRADO", "XML_EXISTENTE"):
                raise RuntimeError("Resultado de registro XML no reconocido.")
            outcome = "OK"
            dian_code = document.code
        except DianDocumentNotFoundError as error:
            outcome = "NO_ENCONTRADO"
            dian_code = error.code
        except (
            DianConfigurationError,
            DianSoapFaultError,
            ValueError,
            etree.XMLSyntaxError,
        ) as error:
            outcome = "ERROR"
            error_type = type(error).__name__
        except Exception as error:
            outcome = "REINTENTO"
            error_type = type(error).__name__

        duration_ms = max(0, int((time.perf_counter() - started) * 1000))
        finalized = repository.finish_document(
            consultation_id, outcome, settings.max_document_attempts,
            dian_code=dian_code[:50] if dian_code else None,
            error_type=error_type,
            duration_ms=duration_ms,
        )
        retry_queued = bool(finalized["Reintentar"])
        if retry_queued:
            storage.enqueue_document(
                message.to_payload(),
                delay_seconds=settings.document_retry_delay_seconds,
            )
        return DocumentProcessingSummary(
            message.document_id, consultation_id, str(finalized["Resultado"]),
            retry_queued=retry_queued,
        )
