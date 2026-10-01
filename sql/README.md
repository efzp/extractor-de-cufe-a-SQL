# Esquema SQL DIAN

Azure SQL es la fuente de verdad de las cargas y documentos DIAN. La Function
usa identidad administrada y solo recibe `EXECUTE` sobre procedimientos
autorizados; no se conceden permisos generales sobre las tablas.

## Orden de despliegue

Para una base de datos nueva, ejecutar en este orden:

1. `migrations/001_create_schema.sql`.
2. `security/dian_runtime.sql`.
3. Las tablas, respetando sus dependencias:
   1. `tables/Cliente.sql`.
   2. `tables/CargaArchivo.sql`.
   3. `tables/Documento.sql`.
   4. `tables/DocumentoVersion.sql`.
   5. `tables/CargaDocumento.sql`.
   6. `tables/DocumentoProcesoHistorial.sql`.
   7. `tables/ConsultaDian.sql`.
   8. `tables/DocumentoXml.sql`.
4. Los procedimientos:
   1. `procedures/sp_RegistrarCliente.sql`.
   2. `procedures/sp_IniciarCargaArchivo.sql`.
   3. `procedures/sp_RegistrarDocumentoCarga.sql`.
   4. `procedures/sp_FinalizarCargaArchivo.sql`.
5. Las pruebas y confirmar el resultado `OK` en cada una:
   1. `tests/test_sp_RegistrarCliente.sql`.
   2. `tests/test_sp_IniciarCargaArchivo.sql`.
   3. `tests/test_sp_RegistrarDocumentoCarga.sql`.
   4. `tests/test_sp_FinalizarCargaArchivo.sql`.

Las pruebas se revierten completamente y no conservan datos.

`migrations/002_carga_archivo_idempotency.sql` es una migración de
actualización para instalaciones anteriores. No hace falta ejecutarla en una
base nueva porque `tables/CargaArchivo.sql` ya contiene el índice de
idempotencia. La migración es segura si se ejecuta por error: comprueba la
existencia del índice antes de crearlo.

Los scripts de tablas representan la línea base ya desplegada. No deben
ejecutarse nuevamente sobre la base actual, porque usan `CREATE TABLE` y los
objetos ya existen.

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

## Contrato de `sp_RegistrarCliente`

El procedimiento registra clientes sin sobrescribir coincidencias existentes
y devuelve:

- `ClienteID`, `Nit`, `RazonSocial` y `Estado` almacenados.
- `Resultado`: `NUEVO`, `EXISTENTE` o `REQUIERE_REVISION`.
- `Creado`: indica si se insertó una fila.
- `RequiereRevision`: indica que el NIT ya existía con datos diferentes.

La operación se serializa por NIT para mantener la idempotencia incluso ante
solicitudes simultáneas. `dian_runtime` recibe únicamente `EXECUTE` sobre el
procedimiento.

## Contrato de registro y finalización de filas

`sp_RegistrarDocumentoCarga` recibe una fila normalizada del listado DIAN. La
primera aparición de un CUFE/CUDE crea el documento y su versión inicial; el
mismo contenido se registra como `DUPLICADO`; un hash de contenido diferente
crea `NUEVA_REVISION` y deja el documento en `REQUIERE_REVISION`. Las filas
inválidas quedan auditadas como `RECHAZADO`. Repetir la misma carga y número de
fila devuelve el registro existente sin duplicarlo.

`sp_FinalizarCargaArchivo` calcula los contadores directamente desde
`CargaDocumento`. Si se informa `TotalFilasEsperadas`, también detecta filas
que la Function no alcanzó a registrar. Devuelve `OK`, `PARCIAL`,
`REQUIERE_REVISION` o `ERROR` y es idempotente ante llamadas repetidas.
