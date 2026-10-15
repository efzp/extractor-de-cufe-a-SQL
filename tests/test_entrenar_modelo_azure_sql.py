from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock, patch

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "entrenar_modelo_azure_sql", ROOT / "scripts" / "entrenar_modelo_azure_sql.py"
)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


def filas_ejemplo():
    filas = []
    for xml_id, fecha, etiqueta in (
        (1, date(2026, 1, 1), "A"), (2, date(2026, 1, 2), "A"),
        (3, date(2026, 1, 3), "A"), (4, date(2026, 1, 4), "B"),
        (5, date(2026, 1, 5), "B"), (6, date(2026, 1, 6), "B"),
        (7, date(2026, 2, 1), "NUEVA"), (8, date(2026, 2, 2), "A"),
    ):
        row = {col: None for col in adapter.PREDICTORAS}
        row.update({
            "documento_xml_id": xml_id,
            "fecha_emision": fecha,
            "target_plantilla_cuentas": etiqueta,
            "codigo_industria_proveedor_limpio": " 1000 ; 2000 ",
            "nit_proveedor_norm": "900123456",
            "payable_amount": Decimal("100.50"),
            "tiene_iva": 1,
        })
        filas.append(row)
    return pd.DataFrame(filas)


class EntrenamientoTests(unittest.TestCase):
    def test_consultas_son_select_y_version_explicita(self):
        self.assertIn("WHERE [DatasetVersionID] = ?", adapter.VERSION_SQL)
        self.assertIn("WHERE [DatasetVersionID] = ?", adapter.FILAS_SQL)
        self.assertNotIn("INSERT", adapter.FILAS_SQL.upper())
        self.assertNotIn("[LlaveAsiento]", adapter.FILAS_SQL)

    def test_preparacion_y_particion_sin_filtrar_prueba(self):
        filas = adapter.preparar_filas(filas_ejemplo())
        self.assertEqual("1000", str(filas.iloc[0]["codigo_industria_proveedor_limpio"]))
        self.assertEqual(100.5, filas.iloc[0]["payable_amount"])
        train, test = adapter.partir_temporal(filas, 0.25)
        self.assertEqual([7, 8], test["documento_xml_id"].tolist())
        filtrado, conteos = adapter.filtrar_clases_entrenables(train, 3)
        self.assertEqual({"A", "B"}, set(filtrado[adapter.TARGET]))
        self.assertEqual(3, conteos["A"])
        self.assertNotIn("NUEVA", set(filtrado[adapter.TARGET]))
        self.assertIn("NUEVA", set(test[adapter.TARGET]))

    def test_particion_limita_a_tres_meses_aunque_no_alcance_20_por_ciento(self):
        fechas = ([date(2026, 1, 15)] * 80 + [date(2026, 2, 15)] * 5
                  + [date(2026, 3, 15)] * 5 + [date(2026, 4, 15)] * 5
                  + [date(2026, 5, 15)] * 5)
        filas = pd.DataFrame({adapter.ID: range(1, 101), adapter.FECHA: fechas})
        filas[adapter.FECHA] = pd.to_datetime(filas[adapter.FECHA])
        train, test = adapter.partir_temporal(filas, 0.20, 3)
        self.assertEqual(85, len(train))
        self.assertEqual(15, len(test))
        self.assertEqual(date(2026, 3, 15), test[adapter.FECHA].min().date())

    def test_particion_predeterminada_limita_a_dos_meses(self):
        fechas = ([date(2026, 1, 15)] * 80 + [date(2026, 2, 15)] * 5
                  + [date(2026, 3, 15)] * 5 + [date(2026, 4, 15)] * 5
                  + [date(2026, 5, 15)] * 5)
        filas = pd.DataFrame({adapter.ID: range(1, 101), adapter.FECHA: fechas})
        filas[adapter.FECHA] = pd.to_datetime(filas[adapter.FECHA])
        train, test = adapter.partir_temporal(filas, 0.20)
        self.assertEqual(90, len(train))
        self.assertEqual(10, len(test))
        self.assertEqual(date(2026, 4, 15), test[adapter.FECHA].min().date())

    def test_particion_no_divide_mes_si_supera_20_por_ciento(self):
        fechas = [date(2026, 1, 15)] * 60 + [date(2026, 2, 15)] * 40
        filas = pd.DataFrame({adapter.ID: range(1, 101), adapter.FECHA: fechas})
        filas[adapter.FECHA] = pd.to_datetime(filas[adapter.FECHA])
        train, test = adapter.partir_temporal(filas, 0.20, 3)
        self.assertEqual(60, len(train))
        self.assertEqual(40, len(test))

    def test_oversampling_solo_train_y_exclusion_de_identificadores(self):
        filas = adapter.preparar_filas(filas_ejemplo())
        train, test = adapter.partir_temporal(filas, 0.25)
        duplicado, info = adapter.oversampling_reciente(
            train, test[adapter.FECHA].min(), meses=1, factor=4
        )
        self.assertTrue(info["activo"])
        self.assertEqual(6, info["filas_antes"])
        self.assertEqual("2026-01-01", info["fecha_corte"])
        self.assertEqual("2026-02-01", info["fecha_fin_exclusiva"])
        self.assertNotIn(7, set(duplicado[adapter.ID]))
        self.assertEqual(2, len(test))
        columnas = adapter.datos_modelo(duplicado).columns
        self.assertNotIn(adapter.ID, columnas)
        self.assertNotIn(adapter.FECHA, columnas)
        self.assertEqual(adapter.TARGET, columnas[-1])

    def test_oversampling_ultimo_ano_calendario_antes_de_prueba(self):
        train = pd.DataFrame({
            adapter.ID: [1, 2, 3],
            adapter.FECHA: pd.to_datetime([
                "2025-06-30", "2025-07-01", "2026-06-30"
            ]),
        })
        duplicado, info = adapter.oversampling_reciente(
            train, date(2026, 7, 1), meses=12, factor=2
        )
        self.assertEqual("2025-07-01", info["fecha_corte"])
        self.assertEqual("2026-07-01", info["fecha_fin_exclusiva"])
        self.assertEqual(2, info["filas_recientes"])
        self.assertEqual([1, 2, 3, 2, 3], duplicado[adapter.ID].tolist())

    def test_rechaza_snapshot_incompleto(self):
        connection = Mock()
        meta = pd.DataFrame([{"VersionContrato": 1, "TotalFilas": 8}])
        with patch.object(adapter, "consultar", side_effect=[meta, filas_ejemplo().head(7)]):
            with self.assertRaisesRegex(ValueError, "numero de filas"):
                adapter.cargar_snapshot(connection, 1)

    def test_solo_validar_no_entrena_ni_escribe(self):
        meta = {
            "DatasetVersionID": 1, "ClienteID": 1, "FuenteContable": "ERP_CPA_BAAS",
            "VersionContrato": 1, "TotalFilas": 8,
        }
        connection = Mock()
        with patch.object(adapter, "conectar_sql", return_value=connection), patch.object(
            adapter, "cargar_snapshot", return_value=(meta, filas_ejemplo())
        ), redirect_stdout(io.StringIO()):
            resumen = adapter.main([
                "--dataset-version-id", "1", "--servidor", "sql.test",
                "--base", "db.test", "--salida", "no_se_crea",
                "--fraccion-prueba", "0.25", "--solo-validar",
            ])
        self.assertEqual(2, resumen["filas_prueba"])
        self.assertEqual(1, resumen["filas_prueba_clase_nueva"])
        self.assertEqual(2, resumen["min_observaciones_clase"])
        self.assertEqual(0.25, resumen["fraccion_prueba_real"])
        connection.close.assert_called_once()

    def test_entrenamiento_guarda_modelo_particion_y_metricas(self):
        class FakePredictor:
            last_threshold = None

            def __init__(self, **kwargs):
                self.path = Path(kwargs["path"])
                self.label_count_threshold = kwargs["learner_kwargs"]["label_count_threshold"]
                FakePredictor.last_threshold = self.label_count_threshold
                self.class_labels = ["A", "B"]

            def fit(self, train_data, **kwargs):
                self.path.mkdir()
                self.assert_columns = list(train_data.columns)
                return self

            def predict(self, data):
                return pd.Series(["A"] * len(data))

            def predict_proba(self, data, **kwargs):
                return pd.DataFrame({"A": [0.8] * len(data), "B": [0.2] * len(data)})

            def leaderboard(self, **kwargs):
                return pd.DataFrame([{"model": "prueba", "score_val": 0.5}])

        fake_module = types.ModuleType("autogluon.tabular")
        fake_module.TabularPredictor = FakePredictor
        fake_parent = types.ModuleType("autogluon")
        fake_parent.tabular = fake_module
        meta = {
            "DatasetVersionID": 1, "ClienteID": 1, "FuenteContable": "ERP_CPA_BAAS",
            "VersionContrato": 1, "TotalFilas": 8, "HashCodigoSha256": "a" * 64,
        }
        with tempfile.TemporaryDirectory() as temp, patch.dict(
            sys.modules, {"autogluon": fake_parent, "autogluon.tabular": fake_module}
        ), patch.object(adapter, "conectar_sql", return_value=Mock()), patch.object(
            adapter, "cargar_snapshot", return_value=(meta, filas_ejemplo())
        ), redirect_stdout(io.StringIO()):
            manifest = adapter.main([
                "--dataset-version-id", "1", "--servidor", "sql.test",
                "--base", "db.test", "--salida", temp,
                "--fraccion-prueba", "0.25", "--sin-oversampling-reciente",
            ])
            runs = list(Path(temp).iterdir())
            self.assertEqual(1, len(runs))
            self.assertTrue((runs[0] / "modelo").is_dir())
            self.assertTrue((runs[0] / "particion.csv").is_file())
            self.assertTrue((runs[0] / "predicciones_prueba.csv").is_file())
            self.assertTrue((runs[0] / "leaderboard_interno.csv").is_file())
            saved = json.loads((runs[0] / "manifiesto.json").read_text(encoding="utf-8"))
            self.assertEqual(1, saved["dataset_version"]["DatasetVersionID"])
            self.assertEqual(0.5, manifest["resumen"]["accuracy_prueba_total"])
            self.assertEqual(0.5, manifest["resumen"]["accuracy_top3_prueba_total"])
            self.assertEqual(1, manifest["resumen"]["filas_prueba_clase_nueva"])
            self.assertEqual(2, FakePredictor.last_threshold)


if __name__ == "__main__":
    unittest.main()
