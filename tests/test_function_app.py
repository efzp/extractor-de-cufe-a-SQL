import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import azure.functions as func

import function_app
from dian.errors import DianConfigurationError, DianDocumentNotFoundError
from dian_ingestion.models import IngestionSummary, QueuedLoad


def make_request(payload=None, raw_body=None):
    if raw_body is None:
        raw_body = json.dumps(payload).encode("utf-8")
    return func.HttpRequest(
        method="POST",
        url="http://localhost/api/dian/xml/consultar",
        body=raw_body,
    )


def make_load_request(client_id="1", file_name="listado.xlsx", body=b"PK-xlsx"):
    return func.HttpRequest(
        method="POST",
        url=f"http://localhost/api/dian/cargas/{client_id}",
        headers={"x-file-name": file_name},
        route_params={"cliente_id": client_id},
        body=body,
    )


class DianGetXmlPocFunctionTests(unittest.TestCase):
    CUFE = "a" * 96

    def test_rejects_invalid_cufe_without_calling_service(self):
        with patch.object(function_app, "run_dian_get_xml") as service:
            response = function_app.dian_get_xml_poc(
                make_request({"cufe": "not-a-cufe"})
            )

        self.assertEqual(400, response.status_code)
        self.assertEqual("REJECTED", json.loads(response.get_body())["status"])
        service.assert_not_called()

    def test_returns_poc_result_for_valid_cufe(self):
        expected = {
            "status": "OK",
            "mode": "POC_NO_PERSISTENCE",
            "cufe": self.CUFE,
            "dianCode": "Ok",
            "message": "Documento encontrado",
            "contentType": "application/xml",
            "sizeBytes": 10,
            "xmlBase64": "PGludm9pY2UvPg==",
        }
        with patch.object(
            function_app,
            "run_dian_get_xml",
            return_value=expected,
        ) as service:
            response = function_app.dian_get_xml_poc(
                make_request({"cufe": self.CUFE.upper()})
            )

        self.assertEqual(200, response.status_code)
        self.assertEqual(expected, json.loads(response.get_body()))
        service.assert_called_once_with(self.CUFE)

    def test_maps_missing_document_to_404(self):
        with patch.object(
            function_app,
            "run_dian_get_xml",
            side_effect=DianDocumentNotFoundError("90", "TrackId no encontrado"),
        ):
            response = function_app.dian_get_xml_poc(
                make_request({"cufe": self.CUFE})
            )

        payload = json.loads(response.get_body())
        self.assertEqual(404, response.status_code)
        self.assertEqual("NOT_FOUND", payload["status"])
        self.assertEqual("90", payload["dianCode"])

    def test_returns_sanitized_configuration_error(self):
        with (
            patch.object(
                function_app,
                "run_dian_get_xml",
                side_effect=DianConfigurationError("secret PFX path"),
            ),
            patch.object(function_app.logging, "exception"),
        ):
            response = function_app.dian_get_xml_poc(
                make_request({"cufe": self.CUFE})
            )

        self.assertEqual(503, response.status_code)
        self.assertNotIn("secret", response.get_body().decode("utf-8"))


class DianLoadFunctionTests(unittest.TestCase):
    def test_accepts_xlsx_and_returns_202(self):
        queued = QueuedLoad(
            schema_version=1,
            correlation_id="correlation-1",
            client_id=7,
            file_name="listado.xlsx",
            blob_name="clientes/7/listado.xlsx",
        )
        with patch.object(function_app, "accept_upload", return_value=queued):
            response = function_app.receive_dian_load(make_load_request("7"))

        payload = json.loads(response.get_body())
        self.assertEqual(202, response.status_code)
        self.assertEqual("ACCEPTED", payload["status"])
        self.assertEqual("correlation-1", payload["correlationId"])

    def test_rejects_non_numeric_client_id(self):
        with patch.object(function_app, "accept_upload") as service:
            response = function_app.receive_dian_load(make_load_request("abc"))

        self.assertEqual(400, response.status_code)
        service.assert_not_called()

    def test_queue_trigger_processes_message(self):
        summary = IngestionSummary(
            correlation_id="correlation-1",
            load_id=10,
            status="OK",
            total_rows=2,
            valid_rows=2,
            duplicate_rows=0,
            revision_rows=0,
            error_rows=0,
            queued_documents=2,
        )
        message = SimpleNamespace(get_body=lambda: b'{"schemaVersion":1}')

        with patch.object(
            function_app, "process_queued_load", return_value=summary
        ) as service:
            function_app.process_dian_load(message)

        service.assert_called_once_with('{"schemaVersion":1}')


if __name__ == "__main__":
    unittest.main()
