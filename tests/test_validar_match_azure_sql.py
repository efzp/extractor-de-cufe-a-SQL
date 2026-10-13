from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validar_match_azure_sql", ROOT / "scripts" / "validar_match_azure_sql.py"
)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


class AdapterSqlTests(unittest.TestCase):
    def test_carga_dian_filtra_solo_facturas(self):
        with patch.object(adapter, "consultar", side_effect=["facturas", "movimientos"]) as consultar:
            result = adapter.cargar_datos(object(), 1, "ERP_CPA_BAAS", 4)
        self.assertEqual(("facturas", "movimientos"), result)
        sql_facturas, params_facturas = consultar.call_args_list[0].args[1:]
        sql_movimientos, params_movimientos = consultar.call_args_list[1].args[1:]
        self.assertIn("[CargaArchivoID] = ?", sql_facturas)
        self.assertEqual((1, 1, 4), params_facturas)
        self.assertNotIn("[CargaArchivoID]", sql_movimientos)
        self.assertEqual((1, "ERP_CPA_BAAS"), params_movimientos)

    def test_sin_filtro_carga(self):
        with patch.object(adapter, "consultar", side_effect=["facturas", "movimientos"]) as consultar:
            adapter.cargar_datos(object(), 1, "ERP_CPA_BAAS", None)
        sql_facturas, params_facturas = consultar.call_args_list[0].args[1:]
        self.assertNotIn("[CargaArchivoID]", sql_facturas)
        self.assertEqual((1,), params_facturas)


try:
    import pandas as pd
except ImportError:
    pd = None


@unittest.skipIf(pd is None, "pandas no instalado en este entorno")
class AdapterMatchingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.historicos = Path.home() / "OneDrive - TCP BAAS S.A.S" / "Automatización"
        if not (cls.historicos / "procesamiento_facturas_contabilidad_match.py").is_file():
            raise unittest.SkipTest("Scripts historicos no disponibles")
        cls.motor, _, _ = adapter.cargar_motor(cls.historicos)

    @staticmethod
    def datos_sinteticos():
        facturas = pd.DataFrame([{
            "id_carga": "dian:1", "id_factura": "FV123", "cufe": "a" * 96,
            "factura_completa": "FV123", "fecha_emision": date(2026, 1, 10),
            "nit_proveedor": "900123456", "nombre_proveedor": "Proveedor X",
            "payable_amount": Decimal("1000.0000"),
            "line_extension_amount": Decimal("1000.0000"),
            "tax_exclusive_amount": Decimal("1000.0000"),
            "tax_inclusive_amount": Decimal("1000.0000"),
            "iva_total": Decimal("0.0000"), "inc_total": Decimal("0.0000"),
        }])
        movimientos = pd.DataFrame([
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
        return facturas, movimientos

    def test_match_sintetico_reutiliza_motor_historico(self):
        facturas, movimientos = self.datos_sinteticos()
        result = adapter.ejecutar_match(self.motor, facturas, movimientos)
        self.assertEqual("OK_UNICO", result["matches"].iloc[0]["estado_match"])
        self.assertEqual(
            ("220505_C", "510505_D"),
            result["dataset"].iloc[0]["target_plantilla_cuentas"],
        )

    def test_main_exporta_reporte_y_compara_referencia(self):
        facturas, movimientos = self.datos_sinteticos()
        esperado = adapter.ejecutar_match(self.motor, facturas, movimientos)
        with tempfile.TemporaryDirectory() as temp:
            carpeta = Path(temp)
            referencia = carpeta / "referencia.xlsx"
            esperado["matches"].to_excel(referencia, index=False)
            conexion = Mock()
            with patch.object(adapter, "conectar_sql", return_value=conexion), patch.object(
                adapter, "cargar_datos", return_value=(facturas, movimientos)
            ), redirect_stdout(io.StringIO()):
                result = adapter.main([
                    "--scripts-historicos", str(self.historicos),
                    "--servidor", "servidor.prueba", "--base", "db_prueba",
                    "--salida", str(carpeta), "--referencia", str(referencia),
                ])
            self.assertEqual(0, result)
            conexion.close.assert_called_once()
            salida = next(carpeta.glob("validacion_*"))
            resumen = json.loads((salida / "resumen.json").read_text(encoding="utf-8"))
            self.assertEqual(1, resumen["matches_aceptados"])
            self.assertEqual(100.0, resumen["cobertura_match_pct"])
            self.assertEqual(1, resumen["comparacion_referencia"]["mismo_asiento"])
            self.assertTrue((salida / "matches.xlsx").is_file())
            self.assertTrue((salida / "comparacion_referencia.xlsx").is_file())

    def test_colision_llave_factura_falla(self):
        df = pd.DataFrame({
            "cufe": ["a" * 96, "b" * 96],
            "llave_factura": ["900123456|fv123", "900123456|fv123"],
        })
        with self.assertRaisesRegex(ValueError, "llave_factura repetido"):
            adapter.validar_llaves(df)

    def test_xlsx_preserva_cadena_que_parece_formula(self):
        with tempfile.TemporaryDirectory() as temp:
            ruta = Path(temp) / "literal.xlsx"
            adapter.escribir_xlsx(pd.DataFrame({"CONCEPTO": ["=1+2"]}), ruta)
            from openpyxl import load_workbook

            libro = load_workbook(ruta, read_only=True)
            try:
                celda = libro["Datos"]["A2"]
                self.assertEqual("s", celda.data_type)
                self.assertEqual("=1+2", celda.value)
            finally:
                libro.close()


if __name__ == "__main__":
    unittest.main()
