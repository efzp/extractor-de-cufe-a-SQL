from __future__ import annotations

import hashlib
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import Mock, patch

import pandas as pd

from ml_inferencia import publicacion
from scripts.entrenar_modelo_azure_sql import PREDICTORAS


class PublicacionTests(unittest.TestCase):
    def test_hash_variables_es_estable_y_sensible_a_cambios(self):
        fila = pd.Series({columna: pd.NA for columna in PREDICTORAS})
        fila["nit_proveedor_norm"] = "901913064"
        fila["payable_amount"] = 28500.0
        primero = publicacion.hash_variables(fila)
        self.assertEqual(64, len(primero))
        self.assertEqual(primero, publicacion.hash_variables(fila.copy()))
        fila["payable_amount"] = 28501.0
        self.assertNotEqual(primero, publicacion.hash_variables(fila))

    def test_sha256_paquete_local(self):
        with tempfile.TemporaryDirectory() as temporal:
            ruta = Path(temporal) / "modelo.tar.gz"
            ruta.write_bytes(b"paquete")
            self.assertEqual(hashlib.sha256(b"paquete").hexdigest(), publicacion.sha256_archivo(ruta))

    def test_ids_explicitamente_seleccionados_y_fuera_del_dataset(self):
        facturas = pd.DataFrame({"DocumentoXmlID": [470, 471], "cufe": ["a" * 96, "b" * 96]})
        with patch.object(publicacion, "query_frame", return_value=facturas) as query:
            resultado = publicacion.consultar_facturas_ids(Mock(), 1, 1, [471, 470])
        self.assertEqual([470, 471], resultado["DocumentoXmlID"].tolist())
        sql, parametros = query.call_args.args[1:]
        self.assertIn("v.[DocumentoXmlID] IN (?, ?)", sql)
        self.assertIn("f.[DatasetVersionID] = ?", sql)
        self.assertEqual((1, 471, 470, 1), parametros)

    def test_rechaza_id_faltante(self):
        facturas = pd.DataFrame({"DocumentoXmlID": [470], "cufe": ["a" * 96]})
        with patch.object(publicacion, "query_frame", return_value=facturas):
            with self.assertRaisesRegex(ValueError, "471"):
                publicacion.consultar_facturas_ids(Mock(), 1, 1, [470, 471])

    def test_probabilidad_se_redondea_como_sql(self):
        self.assertEqual(Decimal("0.397503435612"), publicacion._probabilidad(0.39750343561172485))
        with self.assertRaises(ValueError):
            publicacion._probabilidad(1.2)


if __name__ == "__main__":
    unittest.main()
