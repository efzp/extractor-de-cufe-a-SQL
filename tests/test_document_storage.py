import hashlib
import unittest
from types import SimpleNamespace

from azure.core.exceptions import ResourceExistsError

from dian_ingestion.storage import StorageGateway


class FakeBlob:
    def __init__(self, existing=None):
        self.existing = existing
        self.uploads = []
        self.url = "https://storage.blob.core.windows.net/xml-dian/path.xml"

    def upload_blob(self, content, **kwargs):
        self.uploads.append((content, kwargs))
        if self.existing is not None:
            raise ResourceExistsError("already exists")

    def download_blob(self):
        return SimpleNamespace(readall=lambda: self.existing)


class FakeBlobService:
    def __init__(self, blob):
        self.blob = blob
        self.calls = []

    def get_blob_client(self, **kwargs):
        self.calls.append(kwargs)
        return self.blob


class FakeQueue:
    def __init__(self):
        self.messages = []

    def send_message(self, *args, **kwargs):
        self.messages.append((args, kwargs))


class DocumentStorageTests(unittest.TestCase):
    def make_gateway(self, blob):
        gateway = StorageGateway.__new__(StorageGateway)
        gateway._settings = SimpleNamespace(
            xml_container="xml-dian", document_queue="documentos-pendientes"
        )
        gateway._blob_service = FakeBlobService(blob)
        queue = FakeQueue()
        gateway._queue_service = SimpleNamespace(get_queue_client=lambda _: queue)
        return gateway, queue

    def test_upload_uses_deterministic_name_and_content_type(self):
        blob = FakeBlob()
        gateway, _ = self.make_gateway(blob)
        content = b"<Invoice/>"

        uri, digest = gateway.upload_document(7, 20, content)

        self.assertEqual(hashlib.sha256(content).hexdigest(), digest)
        self.assertEqual(blob.url, uri)
        self.assertEqual(
            f"clientes/7/documentos/20/{digest}.xml",
            gateway._blob_service.calls[0]["blob"],
        )
        self.assertFalse(blob.uploads[0][1]["overwrite"])
        self.assertEqual(
            "application/xml", blob.uploads[0][1]["content_settings"].content_type
        )

    def test_existing_identical_blob_is_idempotent_but_different_fails(self):
        content = b"<Invoice/>"
        gateway, _ = self.make_gateway(FakeBlob(existing=content))
        gateway.upload_document(7, 20, content)

        gateway, _ = self.make_gateway(FakeBlob(existing=b"<Different/>"))
        with self.assertRaises(RuntimeError):
            gateway.upload_document(7, 20, content)

    def test_delayed_requeue_sets_visibility_timeout(self):
        gateway, queue = self.make_gateway(FakeBlob())

        gateway.enqueue_document({"schemaVersion": 1}, delay_seconds=60)

        self.assertEqual(60, queue.messages[0][1]["visibility_timeout"])


if __name__ == "__main__":
    unittest.main()
