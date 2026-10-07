import json
import unittest
from datetime import datetime
from io import BytesIO
from unittest.mock import patch

import azure.functions as func
from openpyxl import Workbook

import function_app
from contabilidad_ingestion.config import AccountingSettings
from contabilidad_ingestion.models import AccountingQueuedLoad
from contabilidad_ingestion.reader import read_accounting_workbook
from contabilidad_ingestion.service import (
    accept_accounting_upload,
    process_accounting_load,
)
from dian_ingestion.errors import SpreadsheetValidationError


SETTINGS = AccountingSettings(
    storage_account="storage",
    load_container="cargas-contabilidad",
    load_queue="contabilidad-cargas-pendientes",
    sql_server="server.database.windows.net",
    sql_database="database",
    sql_driver="ODBC Driver 18 for SQL Server",
    max_upload_bytes=1024 * 1024,
    max_rows=50000,
)

HEADERS = [
    "FECHA", "DOCUMENTO", "TIPODOC", "NUMDOC", "CUENTA",
    "NOM_CUENTA", "CONCEPTO", "NATURALEZA", "CENTRO", "DEBITO",
    "CREDITO", "IDENTIDADTERCERO", "DOC_FUENTE", "FECHA_SISTEMA",
    "IND_CONTABILIDAD", "C_C",
]


def workbook_bytes(*, with_mobile=False, blank=False):
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Sheet1"
    headers = HEADERS + (["NUMERO_MOVIL"] if with_mobile else [])
    sheet.append(headers)
    if not blank:
        sheet.append(
            [
                "2026/02/28", "NB  00000248", "NB", "00000248", "511585",
                "GMF", "Gastos bancarios", "D", "13", "206326.4",
                0, "860003020", None, datetime(2026, 5, 29, 8, 57, 17),
                "133802", "13 - OUTSOURCING CONTABLE",
            ] + (["3001234567"] if with_mobile else [])
        )
    buffer = BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


class FakeStorage:
    def __init__(self, content):
        self.content = content
        self.uploaded = []
        self.enqueued = []
        self.deleted = []
        self.fail_enqueue = False

    def upload_load(self, name, content):
        self.uploaded.append((name, content))

    def enqueue_load(self, message):
        if self.fail_enqueue:
            raise RuntimeError("queue unavailable")
        self.enqueued.append(message)

    def delete_load(self, name):
        self.deleted.append(name)

    def download_load(self, name):
        return self.content


class FakeRepository:
    def __init__(self, status="RECIBIDA"):
        self.status = status
        self.started = []
        self.registered = []
        self.finished = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def start_load(self, *args):
        self.started.append(args)
        return {"CargaArchivoID": 7, "Estado": self.status}

    def register_movement(self, load_id, row):
        self.registered.append((load_id, row))
        return {"Resultado": "NUEVO"}

    def finish_load(self, load_id, total):
        self.finished.append((load_id, total))
        return {
            "Estado": "OK", "TotalFilas": total, "FilasNuevas": total,
            "FilasDuplicadas": 0, "FilasConflicto": 0, "FilasRechazadas": 0,
        }


class AccountingReaderTests(unittest.TestCase):
    def test_old_and_new_columns_normalize_dates_and_keep_identifiers(self):
        for mobile in (False, True):
            with self.subTest(mobile=mobile):
                book = read_accounting_workbook(workbook_bytes(with_mobile=mobile))
                self.assertEqual("Sheet1", book.sheet_name)
                self.assertEqual(1, len(book.rows))
                self.assertEqual(2, book.rows[0].row_number)
                row = json.loads(book.rows[0].json_text)
                self.assertEqual("2026-02-28", row["Fecha"])
                self.assertEqual("00000248", row["NumDoc"])
                self.assertEqual("2026-05-29T08:57:17.000", row["FechaSistema"])
                self.assertEqual("206326.4", row["Debito"])
                self.assertEqual("133802", row["IndContabilidad"])
                self.assertEqual(mobile, "NumeroMovil" in row)

    def test_rejects_empty_and_wrong_sheet(self):
        with self.assertRaises(SpreadsheetValidationError):
            read_accounting_workbook(workbook_bytes(blank=True))
        with self.assertRaises(SpreadsheetValidationError):
            read_accounting_workbook(workbook_bytes(), "missing")

    def test_enforces_row_limit(self):
        with self.assertRaises(SpreadsheetValidationError):
            read_accounting_workbook(workbook_bytes(), max_rows=0)

        workbook = Workbook()
        sheet = workbook.active
        sheet.append(HEADERS)
        sheet.append(["2026/02/28"] + [None] * (len(HEADERS) - 1))
        sheet.append(["2026/02/28"] + [None] * (len(HEADERS) - 1))
        buffer = BytesIO()
        workbook.save(buffer)
        with self.assertRaises(SpreadsheetValidationError):
            read_accounting_workbook(buffer.getvalue(), max_rows=1)


class AccountingServiceTests(unittest.TestCase):
    def test_accept_upload_queues_ascii_json_and_preserves_unicode_name(self):
        content = workbook_bytes()
        storage = FakeStorage(content)
        message = accept_accounting_upload(
            1, "ERP_CPA_BAAS", "Movimiento contable añó.xlsx", content,
            settings=SETTINGS, storage=storage,
        )
        self.assertEqual("Movimiento contable añó.xlsx", message.file_name)
        self.assertEqual(1, len(storage.uploaded))
        self.assertTrue(storage.enqueued[0].isascii())
        self.assertEqual(message, AccountingQueuedLoad.from_json(storage.enqueued[0]))

    def test_enqueue_failure_removes_only_new_blob(self):
        content = workbook_bytes()
        storage = FakeStorage(content)
        storage.fail_enqueue = True
        with self.assertRaises(RuntimeError):
            accept_accounting_upload(
                1, "ERP_CPA_BAAS", "carga.xlsx", content,
                settings=SETTINGS, storage=storage,
            )
        self.assertEqual([storage.uploaded[0][0]], storage.deleted)

    def test_processes_and_finishes_all_rows(self):
        content = workbook_bytes(with_mobile=True)
        storage = FakeStorage(content)
        message = accept_accounting_upload(
            1, "ERP_CPA_BAAS", "carga.xlsx", content,
            settings=SETTINGS, storage=storage,
        )
        repository = FakeRepository()
        result = process_accounting_load(
            message.to_json(), settings=SETTINGS, storage=storage,
            repository_factory=lambda: repository,
        )
        self.assertEqual("OK", result.status)
        self.assertEqual(1, result.new_rows)
        self.assertEqual([(7, 1)], repository.finished)
        self.assertEqual(2, repository.registered[0][1].row_number)

    def test_processing_status_resumes_and_terminal_status_does_not_repeat(self):
        content = workbook_bytes()
        storage = FakeStorage(content)
        message = accept_accounting_upload(
            1, "ERP_CPA_BAAS", "carga.xlsx", content,
            settings=SETTINGS, storage=storage,
        )
        for status, expected in (("PROCESANDO", 1), ("OK", 0)):
            with self.subTest(status=status):
                repository = FakeRepository(status)
                process_accounting_load(
                    message.to_json(), settings=SETTINGS, storage=storage,
                    repository_factory=lambda: repository,
                )
                self.assertEqual(expected, len(repository.registered))


class AccountingFunctionTests(unittest.TestCase):
    def test_http_rejects_invalid_client_id(self):
        request = func.HttpRequest(
            method="POST", url="http://localhost/api/contabilidad/cargas/abc",
            route_params={"cliente_id": "abc"}, body=b"xlsx",
        )
        with patch.object(function_app, "accept_accounting_upload") as service:
            response = function_app.receive_accounting_load(request)
        self.assertEqual(400, response.status_code)
        service.assert_not_called()

    def test_http_receives_query_metadata_not_unicode_headers(self):
        request = func.HttpRequest(
            method="POST",
            url="http://localhost/api/contabilidad/cargas/1?fuenteContable=ERP_CPA_BAAS&nombreArchivo=carga.xlsx",
            route_params={"cliente_id": "1"},
            params={"fuenteContable": "ERP_CPA_BAAS", "nombreArchivo": "carga.xlsx"},
            body=b"xlsx",
        )
        queued = AccountingQueuedLoad(
            correlation_id="8ac2eaae-2ab4-4974-9b66-604be55598ae",
            client_id=1,
            source="ERP_CPA_BAAS",
            file_name="carga.xlsx",
            blob_name="clientes/1/cargas/2026/10/8ac2eaae-2ab4-4974-9b66-604be55598ae.xlsx",
        )
        with patch.object(function_app, "accept_accounting_upload", return_value=queued) as service:
            response = function_app.receive_accounting_load(request)
        self.assertEqual(202, response.status_code)
        self.assertEqual("ERP_CPA_BAAS", service.call_args.kwargs["source"])

    def test_queue_trigger_invokes_service(self):
        class Message:
            def get_body(self):
                return b'{"schemaVersion":1}'

        with patch.object(function_app, "process_accounting_load") as service:
            service.return_value = type("Summary", (), {
                "correlation_id": "c", "load_id": 1, "status": "OK",
                "total_rows": 1, "new_rows": 1, "duplicate_rows": 0,
                "conflict_rows": 0, "rejected_rows": 0,
            })()
            function_app.process_accounting_queue(Message())
        service.assert_called_once_with('{"schemaVersion":1}')


if __name__ == "__main__":
    unittest.main()
