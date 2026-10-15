from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from scripts.probar_inferencia_blob_azure_sql import descargar_paquete, ejecutar


class BlobFalso:
    def __init__(self, contenido: bytes, metadata: dict[str, str] | None = None):
        self.contenido = contenido
        self.metadata = metadata or {"sha256": hashlib.sha256(contenido).hexdigest()}
        self.descargas = 0

    def get_blob_properties(self):
        return SimpleNamespace(size=len(self.contenido), metadata=self.metadata, etag='"etag"')

    def download_blob(self, **kwargs):
        self.descargas += 1
        return SimpleNamespace(chunks=lambda: [self.contenido[:3], self.contenido[3:]])


class DescargaTests(unittest.TestCase):
    def test_descarga_verificada(self):
        blob = BlobFalso(b"paquete-prueba")
        with tempfile.TemporaryDirectory() as temporal:
            destino = Path(temporal) / "modelo.tar.gz"
            resultado = descargar_paquete(blob, destino, blob.metadata["sha256"])
            self.assertEqual(b"paquete-prueba", destino.read_bytes())
        self.assertEqual(len(blob.contenido), resultado["bytes"])
        self.assertEqual(1, blob.descargas)

    def test_metadata_incorrecta_impide_descarga(self):
        blob = BlobFalso(b"paquete-prueba", {"sha256": "0" * 64})
        with tempfile.TemporaryDirectory() as temporal:
            with self.assertRaisesRegex(ValueError, "metadatos Blob"):
                descargar_paquete(blob, Path(temporal) / "modelo.tar.gz", "1" * 64)
        self.assertEqual(0, blob.descargas)

    def test_contenido_alterado_se_rechaza(self):
        original = hashlib.sha256(b"original").hexdigest()
        blob = BlobFalso(b"alterado", {"sha256": original})
        with tempfile.TemporaryDirectory() as temporal:
            with self.assertRaisesRegex(ValueError, "SHA-256 del paquete descargado"):
                descargar_paquete(blob, Path(temporal) / "modelo.tar.gz", original)

    def test_lote_excesivo_se_rechaza_antes_de_azure(self):
        with self.assertRaisesRegex(ValueError, "1 a 10"):
            ejecutar(
                cuenta="cuenta", contenedor="modelos-ml", blob="modelo.tar.gz",
                sha_paquete="a" * 64, sha_manifiesto="b" * 64,
                servidor="servidor", base="base", driver="ODBC Driver 18 for SQL Server",
                cliente_id=1, xml_ids=list(range(1, 12)),
                nombre_modelo="prueba", publicar=False,
            )


if __name__ == "__main__":
    unittest.main()
