from __future__ import annotations

import unittest
from decimal import Decimal

from scripts import actualizar_contrato_prediccion_plantilla as contrato


class ContratoPrediccionTests(unittest.TestCase):
    def test_fuente_anterior_se_reconstruye_sin_cambiar_los_demases_controles(self):
        nueva = contrato.normalizar(contrato.SQL_PATH.read_text(encoding="utf-8"))
        anterior = contrato.fuente_anterior(nueva)
        self.assertEqual(3, anterior.count("AND [ProbabilidadTop"))
        self.assertNotIn("@ToleranciaProbabilidad", anterior)
        self.assertEqual(3, nueva.count("<= @ToleranciaProbabilidad"))
        self.assertIn("AND [HashVariablesSha256] =", nueva)
        self.assertIn("THROW 50917", nueva)

    def test_limite_cubre_ruido_observado_sin_aceptar_cambio_material(self):
        almacenado = Decimal("0.39750344")
        repetido = Decimal("0.397503376007")
        tolerancia = Decimal("0.000001")
        self.assertLessEqual(abs(almacenado - repetido), tolerancia)
        self.assertGreater(abs(almacenado - Decimal("0.39750544")), tolerancia)


if __name__ == "__main__":
    unittest.main()
