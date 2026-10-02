from __future__ import annotations

import hashlib
import json
from typing import Any

from .config import IngestionSettings


class StorageGateway:
    def __init__(self, settings: IngestionSettings, credential=None):
        if credential is None:
            from azure.identity import DefaultAzureCredential

            credential = DefaultAzureCredential(
                exclude_interactive_browser_credential=True
            )

        from azure.storage.blob import BlobServiceClient
        from azure.storage.queue import QueueServiceClient

        self._settings = settings
        self._blob_service = BlobServiceClient(
            account_url=settings.storage_account_url,
            credential=credential,
        )
        self._queue_service = QueueServiceClient(
            account_url=settings.queue_account_url,
            credential=credential,
        )

    def upload_load(self, blob_name: str, content: bytes) -> None:
        from azure.storage.blob import ContentSettings

        blob = self._blob_service.get_blob_client(
            container=self._settings.load_container,
            blob=blob_name,
        )
        blob.upload_blob(
            content,
            overwrite=False,
            content_settings=ContentSettings(
                content_type=(
                    "application/vnd.openxmlformats-officedocument."
                    "spreadsheetml.sheet"
                )
            ),
        )

    def download_load(self, blob_name: str) -> bytes:
        blob = self._blob_service.get_blob_client(
            container=self._settings.load_container,
            blob=blob_name,
        )
        return blob.download_blob().readall()

    def delete_load(self, blob_name: str) -> None:
        blob = self._blob_service.get_blob_client(
            container=self._settings.load_container,
            blob=blob_name,
        )
        blob.delete_blob(delete_snapshots="include")

    def enqueue_load(self, message: str) -> None:
        self._queue_service.get_queue_client(
            self._settings.load_queue
        ).send_message(message)

    def enqueue_document(
        self, payload: dict[str, Any], *, delay_seconds: int = 0
    ) -> None:
        message = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        queue = self._queue_service.get_queue_client(self._settings.document_queue)
        if delay_seconds:
            queue.send_message(message, visibility_timeout=delay_seconds)
        else:
            queue.send_message(message)

    def upload_document(
        self, client_id: int, document_id: int, content: bytes
    ) -> tuple[str, str]:
        from azure.core.exceptions import ResourceExistsError
        from azure.storage.blob import ContentSettings

        digest = hashlib.sha256(content).hexdigest()
        name = f"clientes/{client_id}/documentos/{document_id}/{digest}.xml"
        blob = self._blob_service.get_blob_client(
            container=self._settings.xml_container, blob=name
        )
        try:
            blob.upload_blob(
                content,
                overwrite=False,
                content_settings=ContentSettings(content_type="application/xml"),
            )
        except ResourceExistsError:
            if blob.download_blob().readall() != content:
                raise RuntimeError("El Blob XML existente tiene contenido diferente.")
        return blob.url, digest
