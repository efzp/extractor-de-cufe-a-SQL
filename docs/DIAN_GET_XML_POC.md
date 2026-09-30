# Prueba de consulta XML DIAN

La Function `DianGetXmlPoc` verifica la integración SOAP
`GetXmlByDocumentKey` antes de crear persistencia, colas o flujos de SharePoint.
No escribe en Azure SQL ni guarda archivos.

## Contrato HTTP

```http
POST /api/dian/xml/consultar
Content-Type: application/json
x-functions-key: <function-key>

{
  "cufe": "<CUFE-SHA384-DE-96-CARACTERES>"
}
```

Una respuesta correcta incluye metadatos y el XML en `xmlBase64`:

```json
{
  "status": "OK",
  "mode": "POC_NO_PERSISTENCE",
  "cufe": "...",
  "dianCode": "Ok",
  "message": "...",
  "contentType": "application/xml",
  "sizeBytes": 12345,
  "xmlBase64": "..."
}
```

## Configuración temporal del certificado

Para una prueba local, copie `local.settings.example.json` como
`local.settings.json` y configure **solamente una** fuente del certificado:

- `DIAN_PFX_PATH`: ruta absoluta local al `.p12` o `.pfx`.
- `DIAN_PFX_BASE64`: PFX completo codificado en Base64, para una prueba
  controlada en Azure.

También se requiere `DIAN_PFX_PASSWORD`. Los archivos `.p12` y `.pfx`, la
contraseña y `local.settings.json` están excluidos del repositorio. No se debe
registrar el SOAP completo porque contiene el certificado público y el XML de
la factura.

La opción Base64 es transitoria para comprobar conectividad. La fase productiva
debe reemplazarla por firma remota con Azure Key Vault y Managed Identity.

## Prueba local

```powershell
func start
```

En otra consola:

```powershell
$body = @{ cufe = "<CUFE>" } | ConvertTo-Json
Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:7071/api/dian/xml/consultar" `
  -ContentType "application/json" `
  -Body $body
```

La prueba real requiere un CUFE perteneciente al NIT emisor o receptor del
certificado utilizado.
