import re
import struct
from pathlib import Path

import pyodbc
from azure.identity import AzureCliCredential


FILES = (
    Path("sql/procedures/sp_IniciarConsultaDocumento.sql"),
    Path("sql/procedures/sp_RegistrarXmlDocumento.sql"),
    Path("sql/procedures/sp_FinalizarConsultaDocumento.sql"),
    Path("sql/tests/test_ProcesamientoDocumentoDian.sql"),
)

token = AzureCliCredential().get_token(
    "https://database.windows.net/.default"
).token.encode("utf-16-le")
connection = pyodbc.connect(
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=tcp:sql-dian-xml-cpabaas-dev.database.windows.net,1433;"
    "DATABASE=sqldb-dian-xml-cpabaas-dev;"
    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;",
    attrs_before={1256: struct.pack("=i", len(token)) + token},
    autocommit=True,
)

try:
    cursor = connection.cursor()
    cursor.execute("SET PARSEONLY ON")
    for path in FILES:
        contents = path.read_text(encoding="utf-8-sig")
        batches = re.split(r"(?im)^\s*GO\s*$", contents)
        for batch_number, batch in enumerate(batches, start=1):
            if batch.strip():
                cursor.execute(batch)
                while cursor.nextset():
                    pass
        print(f"PARSE_OK {path} ({len(batches)} batches)")
    cursor.execute("SET PARSEONLY OFF")
    cursor.execute("SET NOEXEC ON")
    for path in FILES:
        contents = path.read_text(encoding="utf-8-sig")
        batches = re.split(r"(?im)^\s*GO\s*$", contents)
        for batch in batches:
            if batch.strip():
                cursor.execute(batch)
                while cursor.nextset():
                    pass
        print(f"COMPILE_OK {path}")
finally:
    connection.close()
