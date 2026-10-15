from __future__ import annotations

import json
import tempfile
import unittest
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock, patch

import pandas as pd

from ml_inferencia import service


def factura_ejemplo():
    engine = service.load_engine()
    row = {column: None for column in engine.COLUMNAS_FACTURAS}
    row.update({
        "id_carga": "dian:1", "id_factura": "FV-1", "cufe": "a" * 96,
        "factura_completa": "FV-1", "fecha_emision": date(2026, 10, 5),
        "nit_proveedor": "901913064", "nombre_proveedor": "Proveedor Uno",
        "ciudad_proveedor": "Bogotá", "codigo_industria_proveedor": "1000;2000",
        "tax_exclusive_amount": Decimal("100.00"),
        "tax_inclusive_amount": Decimal("119.00"),
        "payable_amount": Decimal("119.00"), "iva_total": Decimal("19.00"),
        "inc_total": Decimal("0"), "descuento_total": Decimal("0"),
        "recargo_total": Decimal("0"),
        "DocumentoXmlID": 471, "DocumentoID": 475, "VersionExtractor": 1,
    })
    return pd.DataFrame([row])


def manifiesto():
    return {
        "dataset_version": {"DatasetVersionID": 1, "ClienteID": 1, "VersionContrato": 1},
        "columnas_predictoras": list(service.PREDICTORAS),
        "target": service.TARGET,
        "versiones": {"python": "3.11.9", "autogluon.tabular": "1.6.1"},
    }


class InferenciaTests(unittest.TestCase):
    def test_consulta_es_lectura_y_excluye_dataset(self):
        sql = service.FACTURAS_SQL.upper()
        self.assertIn("SELECT TOP (?)", sql)
        self.assertIn("[DATASETVERSIONID] = ?", sql)
        self.assertIn("[DOCUMENTOXMLID] = V.[DOCUMENTOXMLID]", sql)
        for verbo in ("INSERT", "UPDATE", "DELETE", "MERGE"):
            self.assertNotIn(verbo, sql)

    def test_preparacion_conserva_contrato_y_no_incluye_target(self):
        variables = service.preparar_inferencia(factura_ejemplo())
        self.assertEqual(list(service.PREDICTORAS), list(variables.columns))
        self.assertEqual(1, len(variables))
        self.assertEqual("901913064", str(variables.iloc[0]["nit_proveedor_norm"]))
        self.assertEqual("1000", str(variables.iloc[0]["codigo_industria_proveedor_limpio"]))
        self.assertEqual(119.0, variables.iloc[0]["payable_amount"])
        self.assertEqual(1.0, variables.iloc[0]["tiene_iva"])
        self.assertNotIn(service.TARGET, variables.columns)

    def test_rechaza_manifiesto_de_otro_cliente(self):
        with tempfile.TemporaryDirectory() as temporal:
            carpeta = Path(temporal)
            (carpeta / "modelo").mkdir()
            (carpeta / "manifiesto.json").write_text(
                json.dumps(manifiesto()), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "otro ClienteID"):
                service.cargar_manifiesto(carpeta, 2)
            self.assertEqual(1, service.cargar_manifiesto(carpeta, 1)["dataset_version"]["DatasetVersionID"])

    def test_top3_ordenado_y_asociado_al_xml(self):
        facturas = factura_ejemplo()
        predictor = Mock()
        predictor.predict_proba.return_value = pd.DataFrame({
            "B": [0.2], "A": [0.6], "C": [0.15], "D": [0.05],
        })
        predicciones = service.calcular_top3(
            facturas, service.preparar_inferencia(facturas), predictor
        )
        self.assertEqual(471, predicciones.iloc[0]["documento_xml_id"])
        self.assertEqual(["A", "B", "C"], [predicciones.iloc[0][f"plantilla_top{i}"] for i in (1, 2, 3)])
        self.assertEqual(0.6, predicciones.iloc[0]["probabilidad_top1"])

    def test_guarda_csv_y_traza_local_sin_escribir_sql(self):
        facturas = factura_ejemplo()
        variables = service.preparar_inferencia(facturas)
        predictor = Mock()
        predictor.predict_proba.return_value = pd.DataFrame({
            "A": [0.7], "B": [0.2], "C": [0.1],
        })
        predicciones = service.calcular_top3(facturas, variables, predictor)
        with tempfile.TemporaryDirectory() as temporal:
            ruta, resumen = service.guardar_resultado(
                Path(temporal), facturas, variables, predicciones,
                manifiesto(), "a" * 64,
            )
            self.assertEqual([471], resumen["documento_xml_id"])
            self.assertEqual("a" * 64, resumen["manifest_sha256"])
            self.assertEqual(1, len(pd.read_csv(ruta / "predicciones_top3.csv")))
            self.assertEqual(1, len(pd.read_csv(ruta / "variables_modelo.csv")))
            self.assertTrue((ruta / "resumen.json").is_file())

    def test_solo_validar_cierra_sql_y_no_crea_archivos(self):
        facturas = factura_ejemplo()
        connection = Mock()
        with tempfile.TemporaryDirectory() as temporal, patch.object(
            service, "cargar_manifiesto", return_value=manifiesto()
        ), patch.object(service, "conectar_sql", return_value=connection), patch.object(
            service, "consultar_facturas", return_value=facturas
        ):
            salida = Path(temporal) / "salida"
            resultado = service.ejecutar(
                carpeta_modelo=Path(temporal), servidor="sql.test", base="db.test",
                driver="ODBC Driver 18 for SQL Server", cliente_id=1, limite=1,
                salida_base=salida, solo_validar=True,
            )
            self.assertEqual([471], resultado["documento_xml_id"])
            self.assertFalse(salida.exists())
        connection.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
