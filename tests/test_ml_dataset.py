from __future__ import annotations

import json
import unittest
from datetime import date
from decimal import Decimal
from unittest.mock import Mock, patch

import pandas as pd
import azure.functions as func

import function_app

from ml_dataset.message import DatasetMessage
from ml_dataset import service


class DatasetTests(unittest.TestCase):
    @staticmethod
    def synthetic_data():
        invoices = pd.DataFrame([{
            "ClienteID": 1, "DocumentoID": 7, "DocumentoXmlID": 11,
            "VersionExtractor": 1, "HashXmlSha256": "b" * 64,
            "id_carga": "dian:1", "id_factura": "FV123", "cufe": "a" * 96,
            "factura_completa": "FV123", "fecha_emision": date(2026, 1, 10),
            "nit_proveedor": "900123456", "nombre_proveedor": "Proveedor X",
            "payable_amount": Decimal("1000.0000"),
            "line_extension_amount": Decimal("1000.0000"),
            "tax_exclusive_amount": Decimal("1000.0000"),
            "tax_inclusive_amount": Decimal("1000.0000"),
            "iva_total": Decimal("0.0000"), "inc_total": Decimal("0.0000"),
        }])
        movements = pd.DataFrame([
            {
                "FECHA": date(2026, 1, 11), "TIPODOC": "FC", "NUMDOC": "100",
                "CUENTA": "510505", "IDENTIDADTERCERO": "900123456",
                "CONCEPTO": "Factura FV123", "DEBITO": Decimal("1000.0000"),
                "CREDITO": Decimal("0.0000"),
            },
            {
                "FECHA": date(2026, 1, 11), "TIPODOC": "FC", "NUMDOC": "100",
                "CUENTA": "220505", "IDENTIDADTERCERO": "900123456",
                "CONCEPTO": "Factura FV123", "DEBITO": Decimal("0.0000"),
                "CREDITO": Decimal("1000.0000"),
            },
        ])
        return invoices, movements

    def test_message_contract(self):
        message = DatasetMessage.create(1, " ERP_CPA_BAAS ")
        self.assertEqual("ERP_CPA_BAAS", message.accounting_source)
        self.assertEqual(message, DatasetMessage.from_json(message.to_json()))
        with self.assertRaises(ValueError):
            DatasetMessage.from_json('{"schemaVersion":2}')
        with self.assertRaises(ValueError):
            DatasetMessage.create(True, "ERP_CPA_BAAS")

    def test_matching_historico_y_filas_sql(self):
        invoices, movements = self.synthetic_data()
        engine = service.load_engine()
        dataset = service._run_match(engine, invoices, movements)
        rows = service._training_rows(dataset, invoices)
        self.assertEqual(1, len(rows))
        self.assertEqual(11, rows[0]["documento_xml_id"])
        self.assertEqual("a" * 96, rows[0]["cufe"])
        self.assertEqual("OK_UNICO", rows[0]["estado_match"])
        self.assertEqual("('220505_C', '510505_D')", rows[0]["target_plantilla_cuentas"])
        self.assertEqual(1, rows[0]["version_extractor"])
        self.assertEqual(0, rows[0]["flag_umbral_rf_servicios"])
        self.assertTrue(json.loads(service._canonical_json(rows)))

    def test_hash_inputs_is_stable(self):
        invoices, _ = self.synthetic_data()
        self.assertEqual(service._frame_hash(invoices), service._frame_hash(invoices.copy()))
        changed = invoices.copy()
        changed.loc[0, "id_factura"] = "FV124"
        self.assertNotEqual(service._frame_hash(invoices), service._frame_hash(changed))

    def test_generate_publishes_once(self):
        invoices, movements = self.synthetic_data()
        connection = Mock()
        settings = Mock()
        message = DatasetMessage.create(1, "ERP_CPA_BAAS")
        with patch.object(service, "query_frame", side_effect=[invoices, movements]), patch.object(
            service, "_publish", return_value={"DatasetVersionID": 3, "Resultado": "PUBLICADA"}
        ) as publish:
            result = service.generate_dataset(
                message.to_json(), settings=settings, connector=lambda _: connection
            )
        self.assertEqual("PUBLICADA", result.result)
        self.assertEqual(3, result.dataset_version_id)
        self.assertEqual(1, result.accepted)
        self.assertEqual(1, publish.call_count)
        connection.close.assert_called_once()

    def test_publish_sends_canonical_json_to_stored_procedure(self):
        connection = Mock()
        cursor = connection.cursor.return_value
        cursor.fetchone.return_value = (9, 1, "PUBLICADA")
        cursor.description = [
            ("DatasetVersionID",), ("TotalFilas",), ("Resultado",),
        ]
        message = DatasetMessage.create(1, "ERP_CPA_BAAS")
        row = {"documento_xml_id": 11, "cufe": "a" * 96}
        result = service._publish(
            connection, message, "a" * 64, "b" * 64, "c" * 64, 1, [row]
        )
        self.assertEqual(9, result["DatasetVersionID"])
        sql, *params = cursor.execute.call_args.args
        self.assertIn("[ml].[sp_PublicarDatasetEntrenamientoV1]", sql)
        self.assertEqual([row], json.loads(params[-1]))
        cursor.close.assert_called_once()


class DatasetFunctionTests(unittest.TestCase):
    def test_http_only_enqueues(self):
        request = func.HttpRequest(
            method="POST", url="http://localhost/api/ml/datasets/1",
            route_params={"cliente_id": "1"},
            body=b'{"fuenteContable":"ERP_CPA_BAAS"}',
        )
        with patch.object(function_app, "enqueue_ml_dataset") as enqueue:
            response = function_app.request_training_dataset(request)
        self.assertEqual(202, response.status_code)
        self.assertEqual("ACCEPTED", json.loads(response.get_body())["status"])
        self.assertEqual(1, enqueue.call_count)

    def test_http_rejects_invalid_payload(self):
        request = func.HttpRequest(
            method="POST", url="http://localhost/api/ml/datasets/0",
            route_params={"cliente_id": "0"}, body=b'{}',
        )
        with patch.object(function_app, "enqueue_ml_dataset") as enqueue:
            response = function_app.request_training_dataset(request)
        self.assertEqual(400, response.status_code)
        enqueue.assert_not_called()

    def test_queue_invokes_generation(self):
        message = Mock()
        message.get_body.return_value = DatasetMessage.create(1, "ERP_CPA_BAAS").to_json().encode()
        with patch.object(function_app, "generate_dataset") as generate:
            function_app.process_training_dataset(message)
        generate.assert_called_once()

    def test_timer_is_disabled_by_default(self):
        with patch.dict("os.environ", {"ML_DATASET_ENABLED": "false"}), patch.object(
            function_app, "enqueue_ml_dataset"
        ) as enqueue:
            function_app.schedule_training_dataset(Mock())
        enqueue.assert_not_called()


if __name__ == "__main__":
    unittest.main()
