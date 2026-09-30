# Esquema SQL DIAN

Azure SQL es la fuente de verdad de las cargas y documentos DIAN. La Function
usa identidad administrada y solo recibe `EXECUTE` sobre procedimientos
autorizados; no se conceden permisos generales sobre las tablas.

## Orden de despliegue

1. Ejecutar los scripts base de tablas.
2. Ejecutar `migrations/002_carga_archivo_idempotency.sql`.
3. Ejecutar `procedures/sp_IniciarCargaArchivo.sql`.
4. Ejecutar `tests/test_sp_IniciarCargaArchivo.sql` y confirmar el resultado
   `OK`. La prueba se revierte completamente y no conserva datos.

## Contrato de `sp_IniciarCargaArchivo`

El procedimiento devuelve una fila con:

- `CargaArchivoID`.
- `CargaOriginalID`.
- `Estado`.
- `Resultado`: `NUEVA_CARGA`, `SOLICITUD_EXISTENTE`, `REINTENTO` o
  `SIN_CAMBIOS`.
- `DebeProcesar`.

La misma versión de un archivo de SharePoint se reconoce por `ClienteID`,
`SharePointItemID` y `ETag`. Un archivo distinto con el mismo SHA-256 se
registra para auditoría como `SIN_CAMBIOS`, sin volver a procesar sus filas.
