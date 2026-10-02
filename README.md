# Automatización XML CUFE DIAN

Azure Functions para ingerir listados XLSX de la DIAN, registrar documentos y
su trazabilidad en Azure SQL, y consultar XML mediante CUFE. La integración
SOAP usa SOAP 1.2, WS-Addressing y WS-Security con certificado digital.

La ingestión masiva está implementada en tres etapas:

- `RecibirCargaDian`: recibe el XLSX, lo guarda en Blob y agenda la carga.
- `ProcesarCargaDian`: lee la tabla, normaliza sus filas, escribe mediante
  procedimientos almacenados y encola documentos nuevos.
- `ProcesarDocumentoDian`: consume cada documento, consulta la DIAN, guarda
  el XML en Blob y registra el resultado mediante procedimientos SQL.

`DianGetXmlPoc` continúa disponible como prueba de consulta individual sin
persistencia.

## Preparación local

Requisitos:

- Python 3.11.
- Azure Functions Core Tools 4.
- Certificado `.p12` o `.pfx` con su contraseña.
- CUFE real asociado al NIT emisor o receptor del certificado.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item local.settings.example.json local.settings.json
```

Configure en `local.settings.json` la ruta `DIAN_PFX_PATH` y
`DIAN_PFX_PASSWORD`. Para probar la ingestión también debe configurar Azure
Storage y Azure SQL usando las variables de `local.settings.example.json`. No
copie el certificado ni la contraseña al repositorio.

## Ejecución

```powershell
$env:VIRTUAL_ENV = (Resolve-Path ".venv").Path
$env:PATH = "$env:VIRTUAL_ENV\Scripts;$env:PATH"
func start
```

En otra terminal:

```powershell
$body = @{ cufe = "<CUFE>" } | ConvertTo-Json
Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:7071/api/dian/xml/consultar" `
  -ContentType "application/json" `
  -Body $body
```

Consulte [docs/DIAN_GET_XML_POC.md](docs/DIAN_GET_XML_POC.md) para ver el
contrato completo y las consideraciones de seguridad.

Consulte [docs/DIAN_XLSX_INGESTION.md](docs/DIAN_XLSX_INGESTION.md) para el
contrato del endpoint de cargas, colas, variables y permisos.

Consulte [docs/DEPLOY.md](docs/DEPLOY.md) antes de desplegar: GitHub Actions
prepara el contenedor privado `xml-dian` y su permiso de identidad administrada
antes de publicar la Function.

## Pruebas

```powershell
.\.venv\Scripts\python.exe -m compileall -q function_app.py dian dian_ingestion tests
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```
