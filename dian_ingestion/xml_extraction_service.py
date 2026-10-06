"""Orquesta extracción desde Blob registrado, sin llamar a la DIAN."""

from __future__ import annotations

import hashlib
import json
from urllib.parse import urlsplit

from .config import IngestionSettings
from .sql_repository import SqlRepository
from .storage import StorageGateway
from .xml_extractor import EXTRACTOR_VERSION, XmlExtractionError, extract_ubl


def process_xml_extraction(message_text: str, *, settings=None, storage=None,
                           repository_factory=None) -> dict:
    try:
        message = json.loads(message_text)
    except (TypeError, ValueError) as error:
        raise XmlExtractionError("Mensaje de extracción no es JSON.") from error
    if not isinstance(message, dict) or message.get("schemaVersion") != 1:
        raise XmlExtractionError("Versión de mensaje de extracción no compatible.")
    xml_id = message.get("documentoXmlId")
    if type(xml_id) is not int or xml_id <= 0:
        raise XmlExtractionError("documentoXmlId debe ser entero positivo.")
    settings = settings or IngestionSettings.from_environment()
    storage = storage or StorageGateway(settings)
    repository_factory = repository_factory or (lambda: SqlRepository(settings))
    with repository_factory() as repository:
        metadata = repository.get_xml_for_extraction(xml_id)
        if not metadata or not metadata["EsVigente"]:
            return {"DocumentoXmlID": xml_id, "Resultado": "NO_VIGENTE"}
        if metadata["YaExtraido"]:
            return {"DocumentoXmlID": xml_id, "Resultado": "EXISTENTE"}
        if metadata.get("ErrorRegistrado"):
            return {"DocumentoXmlID": xml_id, "Resultado": "ERROR_REGISTRADO"}
        try:
            extracted = _validate_and_extract(metadata, settings, storage)
        except XmlExtractionError as error:
            repository.record_xml_extraction_error(
                xml_id, EXTRACTOR_VERSION, type(error).__name__, str(error)[:1000]
            )
            return {"DocumentoXmlID": xml_id, "Resultado": "RECHAZADO"}
        result = repository.save_xml_extraction(
            xml_id,
            json.dumps(extracted.header, ensure_ascii=False, separators=(",", ":")),
            json.dumps(extracted.lines, ensure_ascii=False, separators=(",", ":")),
        )
        return {"DocumentoXmlID": xml_id, "Resultado": result["Resultado"],
                "Lineas": len(extracted.lines), "VersionExtractor": EXTRACTOR_VERSION}


def _validate_and_extract(metadata: dict, settings: IngestionSettings,
                          storage: StorageGateway):
    client_id = int(metadata["ClienteID"])
    document_id = int(metadata["DocumentoID"])
    digest = str(metadata["HashXmlSha256"]).strip().lower()
    expected_name = f"clientes/{client_id}/documentos/{document_id}/{digest}.xml"
    expected_uri = f"{settings.storage_account_url}/{settings.xml_container}/{expected_name}"
    uri = str(metadata["BlobUri"])
    parsed = urlsplit(uri)
    if uri != expected_uri or parsed.query or parsed.fragment:
        raise XmlExtractionError("La URI del XML no coincide con la ruta determinística.")
    expected_size = int(metadata["TamanoBytes"])
    if expected_size <= 0 or expected_size > settings.max_xml_bytes:
        raise XmlExtractionError("Tamaño registrado fuera del límite permitido.")
    try:
        content = storage.download_document(expected_name, settings.max_xml_bytes)
    except ValueError as error:
        raise XmlExtractionError(str(error)) from error
    if len(content) != expected_size:
        raise XmlExtractionError("Tamaño Blob distinto al registrado en SQL.")
    if hashlib.sha256(content).hexdigest() != digest:
        raise XmlExtractionError("SHA-256 Blob distinto al registrado en SQL.")
    extracted = extract_ubl(content)
    if extracted.header["uuid"] != str(metadata["ClaveDocumento"]).strip().lower():
        raise XmlExtractionError("UUID/CUFE del XML distinto al Documento SQL.")
    declared_type = metadata.get("TipoXmlDetectado")
    if declared_type and str(declared_type) != extracted.header["xmlType"]:
        raise XmlExtractionError("Tipo UBL distinto al registrado en SQL.")
    return extracted


def enqueue_pending_extractions(*, settings=None, storage=None, repository_factory=None,
                                limit=100) -> int:
    settings = settings or IngestionSettings.from_environment()
    storage = storage or StorageGateway(settings)
    repository_factory = repository_factory or (lambda: SqlRepository(settings))
    with repository_factory() as repository:
        rows = repository.list_pending_xml_extractions(limit, EXTRACTOR_VERSION)
    for row in rows:
        storage.enqueue_xml_extraction(int(row["DocumentoXmlID"]))
    return len(rows)
