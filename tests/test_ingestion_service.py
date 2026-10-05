import json
import unittest
from datetime import date, datetime
from decimal import Decimal

from dian_ingestion.config import IngestionSettings
from dian_ingestion.models import (
    NormalizedDocumentRow,
    QueuedLoad,
    WorkbookData,
)
from dian_ingestion.service import accept_upload, process_queued_load


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


def make_row(row_number, key):
    return NormalizedDocumentRow(
        row_number=row_number,
        document_key=key,
        key_type="CUFE",
        values={
            "tipo_documento": "Factura electrónica",
            "folio": str(row_number),
            "prefijo": "FV",
            "divisa": "COP",
            "forma_pago": "1",
            "medio_pago": "49",
            "fecha_emision": date(2026, 9, 28),
            "fecha_recepcion": datetime(2026, 9, 28, 10, 0),
            "nit_emisor": "900111222",
            "nombre_emisor": "Proveedor",
            "nit_receptor": "860502299",
            "nombre_receptor": "Cliente",
            **{name: Decimal("0") for name in (
                "iva", "ica", "ic", "inc", "timbre", "inc_bolsas",
                "in_carbono", "in_combustibles", "ic_datos", "icl",
                "inpp", "ibua", "icui", "rete_iva", "rete_renta", "rete_ica",
            )},
            "total": Decimal("100"),
            "estado_dian": "Aprobado",
            "grupo": "Recibido",
        },
        row_hash=str(row_number) * 64,
        content_hash="f" * 64,
        original_json=json.dumps({"fila": row_number}),
    )


class FakeStorage:
    def __init__(self):
        self.uploaded = []
        self.load_messages = []
        self.document_messages = []
        self.deleted = []
        self.downloaded = b"PK-xlsx"
        self.fail_enqueue = False

    def upload_load(self, blob_name, content):
        self.uploaded.append((blob_name, content))

    def enqueue_load(self, message):
        if self.fail_enqueue:
            raise RuntimeError("queue error")
        self.load_messages.append(message)

    def delete_load(self, blob_name):
        self.deleted.append(blob_name)

    def download_load(self, blob_name):
        return self.downloaded

    def enqueue_document(self, payload):
        self.document_messages.append(payload)


class FakeRepository:
    def __init__(self):
        self.registered = []
        self.finished = []
        self.finish_messages = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return None

    def start_load(self, message, file_hash, table_name):
        return {
            "CargaArchivoID": 10,
            "Estado": "RECIBIDA",
            "Resultado": "NUEVA_CARGA",
            "DebeProcesar": True,
        }

    def register_document(self, load_id, row):
        self.registered.append((load_id, row))
        if row.row_number == 2:
            return {
                "DocumentoID": 20,
                "DocumentoVersionID": 30,
                "Resultado": "NUEVO",
                "EstadoProceso": "PENDIENTE_DESCARGA",
            }
        return {
            "DocumentoID": 21,
            "DocumentoVersionID": 31,
            "Resultado": "DUPLICADO",
            "EstadoProceso": "PENDIENTE_DESCARGA",
        }

    def finish_load(self, load_id, total_rows, message=None):
        self.finished.append((load_id, total_rows))
        self.finish_messages.append(message)
        return {
            "Estado": "OK" if total_rows else "ERROR",
            "TotalFilas": total_rows,
            "FilasValidas": total_rows,
            "FilasDuplicadas": max(0, total_rows - 1),
            "FilasRevision": 0,
            "FilasError": 0,
        }


class IngestionServiceTests(unittest.TestCase):
    def test_accept_upload_stores_and_enqueues_file(self):
        storage = FakeStorage()

        message = accept_upload(
            client_id=7,
            file_name="listado.xlsx",
            content=b"PK-xlsx",
            settings=SETTINGS,
            storage=storage,
        )

        self.assertEqual(7, message.client_id)
        self.assertEqual(1, len(storage.uploaded))
        self.assertEqual(1, len(storage.load_messages))
        self.assertEqual(message, QueuedLoad.from_json(storage.load_messages[0]))

    def test_accept_upload_deletes_blob_if_queue_fails(self):
        storage = FakeStorage()
        storage.fail_enqueue = True

        with self.assertRaises(RuntimeError):
            accept_upload(
                client_id=7,
                file_name="listado.xlsx",
                content=b"PK-xlsx",
                settings=SETTINGS,
                storage=storage,
            )

        self.assertEqual(1, len(storage.deleted))

    def test_process_load_registers_rows_and_enqueues_only_new_document(self):
        storage = FakeStorage()
        repository = FakeRepository()
        message = QueuedLoad(
            schema_version=1,
            correlation_id="correlation-1",
            client_id=7,
            file_name="listado.xlsx",
            blob_name="cargas/listado.xlsx",
        )
        workbook = WorkbookData(
            sheet_name="Hoja1",
            table_name="Tabla1",
            rows=(make_row(2, "a" * 96), make_row(3, "b" * 96)),
        )

        result = process_queued_load(
            message.to_json(),
            settings=SETTINGS,
            storage=storage,
            repository_factory=lambda: repository,
            workbook_reader=lambda content, table: workbook,
        )

        self.assertEqual("OK", result.status)
        self.assertEqual(2, len(repository.registered))
        self.assertEqual([(10, 2)], repository.finished)
        self.assertEqual(1, len(storage.document_messages))
        self.assertEqual(20, storage.document_messages[0]["documentoId"])

    def test_application_response_is_not_registered_or_queued(self):
        storage = FakeStorage()
        repository = FakeRepository()
        message = QueuedLoad(
            schema_version=1,
            correlation_id="correlation-2",
            client_id=7,
            file_name="listado.xlsx",
            blob_name="cargas/listado.xlsx",
        )
        response_row = make_row(3, "b" * 96)
        response_row.values["tipo_documento"] = "Application response"
        workbook = WorkbookData(
            sheet_name="Hoja1",
            table_name="Tabla1",
            rows=(make_row(2, "a" * 96), response_row),
        )

        result = process_queued_load(
            message.to_json(),
            settings=SETTINGS,
            storage=storage,
            repository_factory=lambda: repository,
            workbook_reader=lambda content, table: workbook,
        )

        self.assertEqual([2], [row.row_number for _, row in repository.registered])
        self.assertEqual([(10, 1)], repository.finished)
        self.assertIn("ApplicationResponse omitidas: 1", repository.finish_messages[0])
        self.assertEqual(1, result.ignored_rows)
        self.assertEqual(1, result.total_rows)
        self.assertEqual(1, len(storage.document_messages))

    def test_only_application_responses_have_no_processable_documents(self):
        storage = FakeStorage()
        repository = FakeRepository()
        message = QueuedLoad(
            schema_version=1,
            correlation_id="correlation-3",
            client_id=7,
            file_name="listado.xlsx",
            blob_name="cargas/listado.xlsx",
        )
        response_row = make_row(2, "a" * 96)
        response_row.values["tipo_documento"] = "ApplicationResponse"
        workbook = WorkbookData("Hoja1", "Tabla1", (response_row,))

        result = process_queued_load(
            message.to_json(),
            settings=SETTINGS,
            storage=storage,
            repository_factory=lambda: repository,
            workbook_reader=lambda content, table: workbook,
        )

        self.assertEqual("ERROR", result.status)
        self.assertEqual(1, result.ignored_rows)
        self.assertEqual([(10, 0)], repository.finished)
        self.assertEqual([], repository.registered)
        self.assertEqual([], storage.document_messages)


if __name__ == "__main__":
    unittest.main()
