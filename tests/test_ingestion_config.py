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

