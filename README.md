# Automatización XML CUFE DIAN

Prueba de concepto de Azure Functions para consultar en la DIAN el XML de un
documento electrónico mediante su CUFE. La solicitud usa SOAP 1.2,
WS-Addressing y WS-Security con un certificado digital PFX.

Este proyecto no guarda archivos ni escribe registros en una base de datos.
La persistencia, SharePoint/OneDrive y el procesamiento masivo se incorporarán
después de validar la llamada autenticada.

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
`DIAN_PFX_PASSWORD`. No copie el certificado ni la contraseña al repositorio.

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

## Pruebas

```powershell
.\.venv\Scripts\python.exe -m compileall -q function_app.py dian tests
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```
