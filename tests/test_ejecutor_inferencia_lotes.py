from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import Mock, patch

import pandas as pd

from ml_inferencia import ejecutor_lotes
from scripts import ejecutar_inferencia_blob_sql


def factura(xml_id: int = 470) -> pd.DataFrame:
    return pd.DataFrame({"DocumentoXmlID": [xml_id], "cufe": ["a" * 96]})


def prediccion(xml_id: int = 470) -> pd.DataFrame:
    return pd.DataFrame({
        "documento_xml_id": [xml_id],
        "plantilla_top1": ["A"], "probabilidad_top1": [0.7],
        "plantilla_top2": ["B"], "probabilidad_top2": [0.2],
        "plantilla_top3": ["C"], "probabilidad_top3": [0.1],
    })


class EjecutorLotesTests(unittest.TestCase):
    def test_seleccion_automatica_excluye_dataset_y_prediccion_del_modelo(self):
        with patch.object(ejecutor_lotes, "query_frame", return_value=factura()) as consulta:
            salida = ejecutor_lotes.seleccionar_facturas(
                Mock(), cliente_id=1, dataset_version_id=2,
                hash_modelo="a" * 64, limite=3, xml_ids=None,
            )
        self.assertEqual([470], salida["DocumentoXmlID"].tolist())
        self.assertEqual((3, 1, 2, "a" * 64), consulta.call_args.args[2])
        sql = consulta.call_args.args[1]
        self.assertIn("[ml].[DatasetFila]", sql)
        self.assertIn("[ml].[PrediccionPlantilla]", sql)
        self.assertIn("p.[ModeloArtefactoSha256] = ?", sql)
        self.assertIn("v.[VersionExtractor] = 1", sql)
        self.assertIn("ORDER BY v.[DocumentoXmlID] DESC", sql)

    def test_ids_explicitamente_elegidos_permiten_verificar_ya_existe(self):
        with patch.object(ejecutor_lotes, "consultar_facturas_ids", return_value=factura()) as consulta:
            ejecutor_lotes.seleccionar_facturas(
                Mock(), cliente_id=1, dataset_version_id=2,
                hash_modelo="a" * 64, limite=3, xml_ids=[470],
            )
        consulta.assert_called_once()
        self.assertEqual([470], consulta.call_args.args[3])

    def test_sin_pendientes_no_carga_predictor_ni_escribe(self):
        with patch.object(ejecutor_lotes, "preparar_inferencia") as preparar:
            salida = ejecutor_lotes.inferir_y_publicar(
                Mock(), carpeta_modelo=Path("modelo"), facturas=pd.DataFrame(),
                cliente_id=1, dataset_version_id=2, nombre_modelo="modelo",
                hash_modelo="a" * 64, hash_manifiesto="b" * 64,
                publicar=True,
            )
        self.assertEqual("SIN_PENDIENTES", salida["resultado"])
        preparar.assert_not_called()

    def test_publicacion_individual_y_reintento_ya_existente(self):
        tabular = ModuleType("autogluon.tabular")
        tabular.TabularPredictor = Mock()
        autogluon = ModuleType("autogluon")
        autogluon.tabular = tabular
        connection = Mock()
        respuestas = [
            {"DocumentoXmlID": 470, "PrediccionPlantillaID": 10,
             "Resultado": "REGISTRADA", "EstadoRevision": "PENDIENTE"},
            {"DocumentoXmlID": 471, "PrediccionPlantillaID": 11,
             "Resultado": "YA_EXISTE", "EstadoRevision": "PENDIENTE"},
        ]
        facturas = pd.DataFrame({"DocumentoXmlID": [470, 471], "cufe": ["a" * 96, "b" * 96]})
        predicciones = pd.concat([prediccion(470), prediccion(471)], ignore_index=True)
        with patch.dict(sys.modules, {"autogluon": autogluon, "autogluon.tabular": tabular}), patch.object(
            ejecutor_lotes, "preparar_inferencia", return_value=pd.DataFrame({"x": [1, 2]})
        ), patch.object(ejecutor_lotes, "calcular_top3", return_value=predicciones), patch.object(
            ejecutor_lotes, "hash_variables", side_effect=["c" * 64, "d" * 64]
        ), patch.object(ejecutor_lotes, "_registrar", side_effect=respuestas) as registrar:
            resultado = ejecutor_lotes.inferir_y_publicar(
                connection, carpeta_modelo=Path("modelo"), facturas=facturas,
                cliente_id=1, dataset_version_id=2, nombre_modelo="modelo",
                hash_modelo="a" * 64, hash_manifiesto="b" * 64, publicar=True,
            )
        self.assertEqual("PUBLICACION_COMPLETA", resultado["resultado"])
        self.assertEqual((1, 1), (resultado["publicadas"], resultado["existentes"]))
        self.assertEqual(2, registrar.call_count)
        connection.cursor.return_value.close.assert_called_once()

    def test_fallo_en_una_fila_detiene_el_lote_y_cierra_cursor(self):
        tabular = ModuleType("autogluon.tabular")
        tabular.TabularPredictor = Mock()
        autogluon = ModuleType("autogluon")
        autogluon.tabular = tabular
        connection = Mock()
        facturas = pd.DataFrame({"DocumentoXmlID": [470, 471], "cufe": ["a" * 96, "b" * 96]})
        predicciones = pd.concat([prediccion(470), prediccion(471)], ignore_index=True)
        with patch.dict(sys.modules, {"autogluon": autogluon, "autogluon.tabular": tabular}), patch.object(
            ejecutor_lotes, "preparar_inferencia", return_value=pd.DataFrame({"x": [1, 2]})
        ), patch.object(ejecutor_lotes, "calcular_top3", return_value=predicciones), patch.object(
            ejecutor_lotes, "hash_variables", side_effect=["c" * 64, "d" * 64]
        ), patch.object(ejecutor_lotes, "_registrar", side_effect=[
            {"DocumentoXmlID": 470, "PrediccionPlantillaID": 10,
             "Resultado": "REGISTRADA", "EstadoRevision": "PENDIENTE"},
            RuntimeError("SQL caido"),
        ]) as registrar:
            with self.assertRaisesRegex(RuntimeError, "SQL caido"):
                ejecutor_lotes.inferir_y_publicar(
                    connection, carpeta_modelo=Path("modelo"), facturas=facturas,
                    cliente_id=1, dataset_version_id=2, nombre_modelo="modelo",
                    hash_modelo="a" * 64, hash_manifiesto="b" * 64, publicar=True,
                )
        self.assertEqual(2, registrar.call_count)
        connection.cursor.return_value.close.assert_called_once()

    def test_cli_seco_por_defecto_y_lote_acotado(self):
        with patch.dict("os.environ", {
            "DIAN_SQL_SERVER": "sql.test", "DIAN_SQL_DATABASE": "db.test"
        }), patch.object(ejecutar_inferencia_blob_sql, "ejecutar", return_value={"resultado": "SOLO_VALIDACION"}) as ejecutar:
            ejecutar_inferencia_blob_sql.main([])
        self.assertFalse(ejecutar.call_args.kwargs["publicar"])
        self.assertEqual(3, ejecutar.call_args.kwargs["limite"])
        self.assertIsNone(ejecutar.call_args.kwargs["xml_ids"])


if __name__ == "__main__":
    unittest.main()
