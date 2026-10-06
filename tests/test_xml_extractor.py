import hashlib
import json
import os
import unittest
from pathlib import Path

from dian_ingestion.xml_extractor import XmlExtractionError, extract_ubl
from dian_ingestion.xml_extraction_service import process_xml_extraction
from dian_ingestion.config import IngestionSettings


KEY = "a" * 96
XML = f'''<Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
 xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
 xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2">
 <cbc:ID>F-123</cbc:ID><cbc:UUID>{KEY}</cbc:UUID>
 <cbc:IssueDate>2026-10-06</cbc:IssueDate><cbc:LineCountNumeric>1</cbc:LineCountNumeric>
 <cac:AccountingSupplierParty><cac:Party><cac:PartyTaxScheme>
 <cbc:RegistrationName>Proveedor</cbc:RegistrationName><cbc:CompanyID>9001</cbc:CompanyID>
 </cac:PartyTaxScheme></cac:Party></cac:AccountingSupplierParty>
 <cac:AccountingCustomerParty><cac:Party><cac:PartyTaxScheme>
 <cbc:RegistrationName>Cliente</cbc:RegistrationName><cbc:CompanyID>9002</cbc:CompanyID>
 </cac:PartyTaxScheme></cac:Party></cac:AccountingCustomerParty>
 <cac:TaxTotal><cac:TaxSubtotal><cbc:TaxAmount currencyID="COP">19.00</cbc:TaxAmount>
 <cac:TaxCategory><cac:TaxScheme><cbc:ID>01</cbc:ID></cac:TaxScheme></cac:TaxCategory>
 </cac:TaxSubtotal></cac:TaxTotal>
 <cac:LegalMonetaryTotal><cbc:LineExtensionAmount currencyID="COP">100.00</cbc:LineExtensionAmount>
 <cbc:TaxExclusiveAmount currencyID="COP">100.00</cbc:TaxExclusiveAmount>
 <cbc:TaxInclusiveAmount currencyID="COP">119.00</cbc:TaxInclusiveAmount>
 <cbc:PayableAmount currencyID="COP">119.00</cbc:PayableAmount></cac:LegalMonetaryTotal>
 <cac:InvoiceLine><cbc:ID>1</cbc:ID><cbc:InvoicedQuantity unitCode="EA">2</cbc:InvoicedQuantity>
 <cbc:LineExtensionAmount currencyID="COP">100.00</cbc:LineExtensionAmount>
 <cac:Item><cbc:Description>Artículo</cbc:Description></cac:Item>
 <cac:Price><cbc:PriceAmount currencyID="COP">50.00</cbc:PriceAmount></cac:Price>
 </cac:InvoiceLine></Invoice>'''.encode("utf-8")


class ParserTests(unittest.TestCase):
    def test_extracts_exact_values_and_line(self):
        result = extract_ubl(XML)
        self.assertEqual(KEY, result.header["uuid"])
        self.assertEqual("19.00", result.header["ivaTotal"])
        self.assertEqual("100.00", result.header["taxExclusiveAmount"])
        self.assertEqual("Artículo", result.lines[0]["description"])
        self.assertEqual("0", result.header["legacyDiscount"])

    def test_rejects_dtd_wrong_count_and_other_type(self):
        samples = (
            b'<!DOCTYPE Invoice [<!ENTITY a "x">]>' + XML,
            XML.replace(b"<cbc:LineCountNumeric>1", b"<cbc:LineCountNumeric>2"),
            XML.replace(b"<Invoice ", b"<ApplicationResponse ").replace(
                b"</Invoice>", b"</ApplicationResponse>"
            ),
        )
        for sample in samples:
            with self.subTest(sample=sample[:30]), self.assertRaises(XmlExtractionError):
                extract_ubl(sample)

    def test_real_corpus_when_supplied(self):
        directory = os.environ.get("DIAN_XML_SAMPLE_DIR")
        if not directory:
            self.skipTest("DIAN_XML_SAMPLE_DIR no definido")
        paths = sorted(Path(directory).glob("*.xml"))
        self.assertGreater(len(paths), 0)
        failures = []
        for path in paths:
            try:
                result = extract_ubl(path.read_bytes())
                self.assertEqual(len(result.lines), result.header["lineCount"])
            except (XmlExtractionError, AssertionError) as error:
                failures.append((path.name[:8], str(error)))
        self.assertEqual([], failures, str(failures[:15]) + f"; total={len(failures)}")


class FakeRepository:
    def __init__(self, metadata):
        self.metadata = metadata
        self.saved = []
        self.errors = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def get_xml_for_extraction(self, xml_id):
        return self.metadata

    def save_xml_extraction(self, xml_id, header, lines):
        self.saved.append((xml_id, json.loads(header), json.loads(lines)))
        return {"Resultado": "REGISTRADA"}

    def record_xml_extraction_error(self, xml_id, version, code, detail):
        self.errors.append((xml_id, version, code, detail))
        return {"Resultado": "ERROR_REGISTRADO"}


class FakeStorage:
    def __init__(self, content):
        self.content = content
        self.downloaded = []

    def download_document(self, name, max_bytes):
        self.downloaded.append(name)
        return self.content


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.settings = IngestionSettings(
            storage_account="storage", load_container="cargas-dian",
            load_queue="cargas-pendientes", document_queue="documentos-pendientes",
            sql_server="sql", sql_database="db", sql_driver="driver",
            max_upload_bytes=1024,
        )
        digest = hashlib.sha256(XML).hexdigest()
        self.metadata = {
            "DocumentoXmlID": 12, "DocumentoID": 20, "ClienteID": 7,
            "ClaveDocumento": KEY, "EsVigente": True, "YaExtraido": False,
            "HashXmlSha256": digest, "TamanoBytes": len(XML),
            "TipoXmlDetectado": "Invoice",
            "BlobUri": f"https://storage.blob.core.windows.net/xml-dian/clientes/7/documentos/20/{digest}.xml",
        }

    def run_service(self, repository, storage):
        return process_xml_extraction(
            '{"schemaVersion":1,"documentoXmlId":12}', settings=self.settings,
            storage=storage, repository_factory=lambda: repository,
        )

    def test_verifies_blob_then_saves(self):
        repo, storage = FakeRepository(self.metadata), FakeStorage(XML)
        outcome = self.run_service(repo, storage)
        self.assertEqual("REGISTRADA", outcome["Resultado"])
        self.assertEqual(1, len(repo.saved[0][2]))
        self.assertEqual(
            f"clientes/7/documentos/20/{self.metadata['HashXmlSha256']}.xml",
            storage.downloaded[0],
        )

    def test_rejects_bad_uri_hash_size_or_cufe_without_saving(self):
        cases = (
            ({"BlobUri": "https://evil.example/xml"}, XML),
            ({"TamanoBytes": len(XML) + 1}, XML),
            ({}, XML + b" "),
            ({"ClaveDocumento": "b" * 96}, XML),
        )
        for changes, content in cases:
            with self.subTest(changes=changes):
                repo = FakeRepository({**self.metadata, **changes})
                outcome = self.run_service(repo, FakeStorage(content))
                self.assertEqual("RECHAZADO", outcome["Resultado"])
            self.assertEqual([], repo.saved)
            self.assertEqual(1, len(repo.errors))

    def test_existing_skips_blob(self):
        repo = FakeRepository({**self.metadata, "YaExtraido": True})
        storage = FakeStorage(XML)
        self.assertEqual("EXISTENTE", self.run_service(repo, storage)["Resultado"])
        self.assertEqual([], storage.downloaded)

    def test_recorded_error_is_not_retried(self):
        repo = FakeRepository({**self.metadata, "ErrorRegistrado": True})
        storage = FakeStorage(XML)
        self.assertEqual("ERROR_REGISTRADO", self.run_service(repo, storage)["Resultado"])
        self.assertEqual([], storage.downloaded)

    def test_transient_storage_error_propagates_without_marking_invalid(self):
        repo = FakeRepository(self.metadata)
        storage = FakeStorage(XML)
        def unavailable(*_):
            raise RuntimeError("storage unavailable")
        storage.download_document = unavailable
        with self.assertRaises(RuntimeError):
            self.run_service(repo, storage)
        self.assertEqual([], repo.errors)


if __name__ == "__main__":
    unittest.main()
