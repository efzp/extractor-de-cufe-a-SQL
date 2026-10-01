import unittest
from io import BytesIO

from openpyxl import Workbook
from openpyxl.worksheet.table import Table

from dian_ingestion.excel_reader import read_dian_workbook


HEADERS = [
    "Tipo de documento",
    "CUFE/CUDE",
    "Folio",
    "Prefijo",
    "Divisa",
    "Forma de Pago",
    "Medio de Pago",
    "Fecha Emisi\ufffdn",
    "Fecha Recepci\ufffdn",
    "NIT Emisor",
    "Nombre Emisor",
    "NIT Receptor",
    "Nombre Receptor",
    "IVA",
    "ICA",
    "IC",
    "INC",
    "Timbre",
    "INC Bolsas",
    "IN Carbono",
    "IN Combustibles",
    "IC Datos",
    "ICL",
    "INPP",
    "IBUA",
    "ICUI",
    "Rete IVA",
    "Rete Renta",
    "Rete ICA",
    "Total",
    "Estado",
    "Grupo",
]


def build_workbook_bytes(document_type="Factura electr\ufffdnica"):
    workbook = Workbook()
    worksheet = workbook.active
    worksheet.title = "Rp_Doc_Prueba"
    worksheet.append(HEADERS)
    worksheet.append(
        [
            document_type,
            "a" * 96,
            "2853",
            "FE",
            "COP",
            "1",
            "49",
            "28-09-2026",
            "2026-09-28T18:57:29",
            "901270956",
            "Proveedor SAS",
            "860502299",
            "Cliente SAS",
            19,
            0,
            0,
            "16.822,50",
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            248129,
            "Aprobado con notificaci\ufffdn",
            "Recibido",
        ]
    )
    worksheet.add_table(Table(displayName="Rp_Doc_Prueba", ref="A1:AF2"))
    output = BytesIO()
    workbook.save(output)
    workbook.close()
    return output.getvalue()


class ExcelReaderTests(unittest.TestCase):
    def test_reads_real_dian_header_variants_and_normalizes_row(self):
        result = read_dian_workbook(build_workbook_bytes())

        self.assertEqual("Rp_Doc_Prueba", result.table_name)
        self.assertEqual(1, len(result.rows))
        row = result.rows[0]
        self.assertEqual(2, row.row_number)
        self.assertEqual("a" * 96, row.document_key)
        self.assertEqual("CUFE", row.key_type)
        self.assertEqual("2026-09-28", row.values["fecha_emision"].isoformat())
        self.assertEqual("2026-09-28T18:57:29", row.values["fecha_recepcion"].isoformat())
        self.assertEqual("16822.50", format(row.values["inc"], "f"))
        self.assertEqual(64, len(row.row_hash))
        self.assertEqual(64, len(row.content_hash))

    def test_classifies_application_response_as_cude(self):
        result = read_dian_workbook(build_workbook_bytes("Application response"))

        self.assertEqual("CUDE", result.rows[0].key_type)

    def test_hashes_are_deterministic(self):
        content = build_workbook_bytes()

        first = read_dian_workbook(content).rows[0]
        second = read_dian_workbook(content).rows[0]

        self.assertEqual(first.row_hash, second.row_hash)
        self.assertEqual(first.content_hash, second.content_hash)


if __name__ == "__main__":
    unittest.main()

