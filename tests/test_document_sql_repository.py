import unittest
from unittest.mock import patch

from dian_ingestion.config import IngestionSettings
from dian_ingestion.document_message import QueuedDocument
from dian_ingestion.sql_repository import SqlRepository


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


class DocumentSqlRepositoryTests(unittest.TestCase):
    def test_calls_installed_procedures_with_expected_parameters(self):
        repository = SqlRepository(SETTINGS)
        message = QueuedDocument(
            correlation_id="corr", client_id=7, load_id=10,
            document_id=20, version_id=30, key_type="CUFE",
            document_key="a" * 96,
        )
        with patch.object(repository, "_execute_one", return_value={}) as execute:
            repository.start_document(message, 5, 540)
            sql, parameters = execute.call_args.args
            self.assertIn("sp_IniciarConsultaDocumento", sql)
            self.assertEqual((20, 7, 10, 30, "a" * 96, 5, 540), parameters)

            repository.register_xml(20, 40, "https://blob/xml.xml", "1" * 64, 10, "Invoice")
            sql, parameters = execute.call_args.args
            self.assertIn("sp_RegistrarXmlDocumento", sql)
            self.assertEqual(
                (20, 40, "https://blob/xml.xml", "1" * 64, 10, "Invoice"),
                parameters,
            )

            repository.finish_document(
                40, "OK", 5, dian_code="Ok", duration_ms=100
            )
            sql, parameters = execute.call_args.args
            self.assertIn("sp_FinalizarConsultaDocumento", sql)
            self.assertEqual((40, "OK", "Ok", 100, None, 5), parameters)


if __name__ == "__main__":
    unittest.main()
