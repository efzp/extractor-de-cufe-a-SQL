import json
import unittest
from types import SimpleNamespace

from dian.errors import (
    DianDocumentNotFoundError,
    DianSoapFaultError,
    DianTransportError,
)
from dian_ingestion.config import IngestionSettings
from dian_ingestion.document_message import DocumentMessageError, QueuedDocument
from dian_ingestion.document_service import process_queued_document


SETTINGS = IngestionSettings(
    storage_account="storage",
    load_container="cargas-dian",
    load_queue="cargas-pendientes",
    document_queue="documentos-pendientes",
    sql_server="server.database.windows.net",
    sql_database="database",
    sql_driver="driver",
    max_upload_bytes=1024,
)
MESSAGE = {
    "schemaVersion": 1,
    "correlationId": "correlation-1",
    "clienteId": 7,
    "cargaArchivoId": 10,
    "documentoId": 20,
    "documentoVersionId": 30,
    "tipoClave": "CUFE",
    "claveDocumento": "A" * 96,
}


class FakeStorage:
    def __init__(self):
        self.uploads = []
        self.requeued = []
        self.fail_enqueue = False

    def upload_document(self, client_id, document_id, content):
        self.uploads.append((client_id, document_id, content))
        return (
            "https://storage.blob.core.windows.net/xml-dian/"
            "clientes/7/documentos/20/" + "1" * 64 + ".xml",
            "1" * 64,
        )

    def enqueue_document(self, payload, *, delay_seconds=0):
        if self.fail_enqueue:
            raise RuntimeError("queue unavailable")
        self.requeued.append((payload, delay_seconds))


class FakeRepository:
    def __init__(self, claim_result="CONSULTA_INICIADA", attempt=1):
        self.claim_result = claim_result
        self.attempt = attempt
        self.started = []
        self.registered = []
        self.finished = []
        self.fail_register = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def start_document(self, message, max_attempts, timeout):
        self.started.append((message, max_attempts, timeout))
        return {
            "Resultado": self.claim_result,
            "ConsultaDianID": 40 if self.claim_result in (
                "CONSULTA_INICIADA", "CONSULTA_EN_PROGRESO"
            ) else None,
            "DebeConsultar": self.claim_result == "CONSULTA_INICIADA",
        }

    def register_xml(self, *args):
        if self.fail_register:
            raise RuntimeError("sql unavailable")
        self.registered.append(args)
        return {"Resultado": "XML_REGISTRADO"}

    def finish_document(self, consultation_id, result, max_attempts, **kwargs):
        self.finished.append((consultation_id, result, max_attempts, kwargs))
        final = "ERROR" if result == "REINTENTO" and self.attempt >= max_attempts else result
        return {"Resultado": final, "Reintentar": final == "REINTENTO"}


def run(repository=None, storage=None, fetch_xml=None, message=None):
    repository = repository or FakeRepository()
    storage = storage or FakeStorage()
    return process_queued_document(
        json.dumps(message or MESSAGE), settings=SETTINGS, storage=storage,
        repository_factory=lambda: repository,
        fetch_xml=fetch_xml or (
            lambda key: SimpleNamespace(xml_bytes=b"<Invoice/>", code="Ok")
        ),
    )


class DocumentMessageTests(unittest.TestCase):
    def test_parses_normalized_key_and_keeps_queue_payload(self):
        parsed = QueuedDocument.from_json(json.dumps(MESSAGE))
        self.assertEqual("a" * 96, parsed.document_key)
        self.assertEqual("a" * 96, parsed.to_payload()["claveDocumento"])

    def test_rejects_invalid_identifiers_key_and_schema(self):
        for changes in (
            {"schemaVersion": 2},
            {"documentoId": True},
            {"clienteId": 0},
            {"tipoClave": "OTRO"},
            {"claveDocumento": "bad"},
            {"correlationId": ""},
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(DocumentMessageError):
                    QueuedDocument.from_json(json.dumps({**MESSAGE, **changes}))
        with self.assertRaises(DocumentMessageError):
            QueuedDocument.from_json("not-json")


class DocumentServiceTests(unittest.TestCase):
    def test_success_uploads_then_registers_then_finalizes(self):
        repository = FakeRepository()
        storage = FakeStorage()
        fetched = []

        def fetch(key):
            fetched.append(key)
            return SimpleNamespace(xml_bytes=b"<Invoice/>", code="Ok")

        summary = run(repository, storage, fetch)

        self.assertEqual("OK", summary.result)
        self.assertEqual(["a" * 96], fetched)
        self.assertEqual([(7, 20, b"<Invoice/>")], storage.uploads)
        self.assertEqual((20, 40), repository.registered[0][:2])
        self.assertEqual("Invoice", repository.registered[0][-1])
        self.assertEqual("OK", repository.finished[0][1])
        self.assertEqual([], storage.requeued)

    def test_active_claim_requeues_without_calling_dian(self):
        repository = FakeRepository("CONSULTA_EN_PROGRESO")
        storage = FakeStorage()

        summary = run(repository, storage, lambda _: self.fail("SOAP called"))

        self.assertTrue(summary.retry_queued)
        self.assertEqual(540, storage.requeued[0][1])
        self.assertEqual([], repository.finished)

    def test_already_registered_skips_soap_and_storage(self):
        repository = FakeRepository("XML_YA_REGISTRADO")
        storage = FakeStorage()

        summary = run(repository, storage, lambda _: self.fail("SOAP called"))

        self.assertEqual("XML_YA_REGISTRADO", summary.result)
        self.assertEqual([], storage.uploads)
        self.assertEqual([], repository.finished)

    def test_not_found_is_terminal(self):
        repository = FakeRepository()
        storage = FakeStorage()

        def not_found(_):
            raise DianDocumentNotFoundError("90", "No encontrado")

        summary = run(repository, storage, not_found)

        self.assertEqual("NO_ENCONTRADO", summary.result)
        self.assertEqual("90", repository.finished[0][3]["dian_code"])
        self.assertEqual([], storage.requeued)

    def test_application_response_xml_is_not_stored_even_if_source_was_mislabeled(self):
        repository = FakeRepository()
        storage = FakeStorage()

        summary = run(
            repository,
            storage,
            lambda _: SimpleNamespace(
                xml_bytes=b"<ApplicationResponse/>", code="Ok"
            ),
        )

        self.assertEqual("ERROR", summary.result)
        self.assertEqual([], storage.uploads)
        self.assertEqual([], repository.registered)
        self.assertEqual("UnsupportedXmlTypeError", repository.finished[0][3]["error_type"])
        self.assertEqual([], storage.requeued)

    def test_transport_error_requeues_after_finalization(self):
        repository = FakeRepository()
        storage = FakeStorage()

        def transport_error(_):
            raise DianTransportError("fallo de red")

        summary = run(repository, storage, transport_error)

        self.assertEqual("REINTENTO", summary.result)
        self.assertEqual("REINTENTO", repository.finished[0][1])
        self.assertEqual(60, storage.requeued[0][1])
        self.assertEqual("DianTransportError", repository.finished[0][3]["error_type"])

    def test_maximum_attempts_does_not_requeue(self):
        repository = FakeRepository(attempt=5)
        storage = FakeStorage()

        def transport_error(_):
            raise DianTransportError("fallo de red")

        summary = run(repository, storage, transport_error)

        self.assertEqual("ERROR", summary.result)
        self.assertEqual([], storage.requeued)

    def test_soap_fault_and_invalid_xml_are_terminal(self):
        for fetch in (
            lambda _: (_ for _ in ()).throw(DianSoapFaultError("fault")),
            lambda _: SimpleNamespace(xml_bytes=b"not xml", code="Ok"),
        ):
            with self.subTest(fetch=fetch):
                repository = FakeRepository()
                storage = FakeStorage()
                summary = run(repository, storage, fetch)
                self.assertEqual("ERROR", summary.result)
                self.assertEqual([], storage.uploads)
                self.assertEqual([], storage.requeued)

    def test_register_failure_retries_after_blob_upload(self):
        repository = FakeRepository()
        repository.fail_register = True
        storage = FakeStorage()

        summary = run(repository, storage)

        self.assertEqual("REINTENTO", summary.result)
        self.assertEqual(1, len(storage.uploads))
        self.assertEqual(1, len(storage.requeued))

    def test_queue_failure_propagates_for_native_queue_retry(self):
        repository = FakeRepository("CONSULTA_EN_PROGRESO")
        storage = FakeStorage()
        storage.fail_enqueue = True

        with self.assertRaisesRegex(RuntimeError, "queue unavailable"):
            run(repository, storage)


if __name__ == "__main__":
    unittest.main()
