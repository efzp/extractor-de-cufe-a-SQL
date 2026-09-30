import json
import unittest
from unittest.mock import patch

import azure.functions as func

import function_app
from dian.errors import DianConfigurationError, DianDocumentNotFoundError


def make_request(payload=None, raw_body=None):
    if raw_body is None:
        raw_body = json.dumps(payload).encode("utf-8")
    return func.HttpRequest(
        method="POST",
        url="http://localhost/api/dian/xml/consultar",
        body=raw_body,
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


if __name__ == "__main__":
    unittest.main()
