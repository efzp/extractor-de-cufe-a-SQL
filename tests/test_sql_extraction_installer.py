import re
import runpy
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "Generar-InstalacionExtraccionXmlDian.py"
INSTALLER = ROOT / "scripts" / "Instalar-ExtraccionXmlDian.sql"


class SqlExtractionInstallerTests(unittest.TestCase):
    def test_single_batch_is_current_and_contains_all_objects(self):
        generated = runpy.run_path(str(GENERATOR))["generate"]()
        self.assertEqual(generated, INSTALLER.read_text(encoding="utf-8"))
        self.assertIsNone(re.search(r"(?im)^\s*GO\s*$", generated))
        self.assertEqual(5, generated.count("EXEC sys.sp_executesql @Definicion;"))
        self.assertEqual(4, generated.count("GRANT EXECUTE ON OBJECT::"))
        self.assertIn("IF DB_NAME() <> N'sqldb-dian-xml-cpabaas-dev'", generated)
        self.assertIn("ROLLBACK TRANSACTION", generated)
        for name in ("XmlExtraccion", "XmlLinea", "XmlExtraccionError"):
            self.assertIn(f"CREATE TABLE [dian].[{name}]", generated)


if __name__ == "__main__":
    unittest.main()
