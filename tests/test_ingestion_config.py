import os
import unittest
from unittest.mock import patch

from dian_ingestion.config import IngestionSettings
from dian_ingestion.errors import IngestionConfigurationError


class IngestionSettingsTests(unittest.TestCase):
    def test_reads_required_settings_and_defaults(self):
        environment = {
            "DIAN_STORAGE_ACCOUNT": "storage",
            "DIAN_SQL_SERVER": "server.database.windows.net",
            "DIAN_SQL_DATABASE": "database",
        }
        with patch.dict(os.environ, environment, clear=True):
            settings = IngestionSettings.from_environment()

        self.assertEqual("cargas-dian", settings.load_container)
        self.assertEqual("cargas-pendientes", settings.load_queue)
        self.assertEqual("documentos-pendientes", settings.document_queue)
        self.assertEqual(20 * 1024 * 1024, settings.max_upload_bytes)
        self.assertEqual("xml-dian", settings.xml_container)
        self.assertEqual(5, settings.max_document_attempts)
        self.assertEqual(540, settings.claim_timeout_seconds)
        self.assertEqual(60, settings.document_retry_delay_seconds)

    def test_rejects_document_limits_outside_sql_contract(self):
        environment = {
            "DIAN_STORAGE_ACCOUNT": "storage",
            "DIAN_SQL_SERVER": "server.database.windows.net",
            "DIAN_SQL_DATABASE": "database",
            "DIAN_CLAIM_TIMEOUT_SECONDS": "86401",
        }
        with patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(IngestionConfigurationError):
                IngestionSettings.from_environment()

        environment["DIAN_CLAIM_TIMEOUT_SECONDS"] = "540"
        environment["DIAN_XML_CONTAINER"] = "otro-contenedor"
        with patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(IngestionConfigurationError):
                IngestionSettings.from_environment()

    def test_rejects_missing_sql_configuration(self):
        with patch.dict(
            os.environ,
            {"DIAN_STORAGE_ACCOUNT": "storage"},
            clear=True,
        ):
            with self.assertRaises(IngestionConfigurationError):
                IngestionSettings.from_environment()


if __name__ == "__main__":
    unittest.main()
