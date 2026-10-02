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
   5. `procedures/sp_IniciarConsultaDocumento.sql`.
   6. `procedures/sp_RegistrarXmlDocumento.sql`.
   7. `procedures/sp_FinalizarConsultaDocumento.sql`.
5. Las pruebas y confirmar el resultado `OK` en cada una:
   1. `tests/test_sp_RegistrarCliente.sql`.
   2. `tests/test_sp_IniciarCargaArchivo.sql`.
   3. `tests/test_sp_RegistrarDocumentoCarga.sql`.
   4. `tests/test_sp_FinalizarCargaArchivo.sql`.
   5. `tests/test_ProcesamientoDocumentoDian.sql`.

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

## Contrato de consulta y XML

`sp_IniciarConsultaDocumento` valida que el cliente, CUFE/CUDE, carga y version
del mensaje correspondan al documento en SQL. Devuelve una fila con
`ConsultaDianID`, `NumeroIntento`, `EstadoProceso`, `Resultado` y
`DebeConsultar`. `CONSULTA_INICIADA` autoriza la llamada SOAP. El consumidor
debe volver a lanzar el mensaje a Azure Queue si recibe
`CONSULTA_EN_PROGRESO`, para que un reclamo abandonado pueda recuperarse al
vencer `TiempoReclamoSegundos`. `XML_YA_REGISTRADO`, `ESTADO_NO_ELEGIBLE` y
`MAXIMO_INTENTOS` no deben consultar de nuevo a la DIAN.

`sp_RegistrarXmlDocumento` se llama despues de guardar el XML en Blob. Exige
una ruta deterministica bajo
`xml-dian/clientes/{clienteId}/documentos/{documentoId}/{hashSha256}.xml`,
registra el hash, URI, tamano y tipo XML, y
devuelve `XML_REGISTRADO` o `XML_EXISTENTE`. Solo permite un XML vigente por
documento y no sobrescribe un XML diferente.

`sp_FinalizarConsultaDocumento` cierra el intento. `OK` requiere un XML
vigente vinculado a la consulta y cambia el documento a `XML_DESCARGADO`;
`NO_ENCONTRADO` es terminal; `REINTENTO` devuelve el documento a
`PENDIENTE_DESCARGA`, salvo cuando se alcanzo `MaximoIntentos`, caso en el que
queda en `ERROR`. Una finalizacion repetida devuelve `YA_FINALIZADA`. Los tres
procedimientos registran las transiciones pertinentes en
`DocumentoProcesoHistorial` y conceden solo `EXECUTE` a `dian_runtime`.

Para el editor web de Azure SQL, ejecutar cada lote `CREATE OR ALTER` de forma
separada y luego su `GRANT`. La prueba SQL requiere instalar antes los tres
procedimientos en un entorno de validacion. Sus datos se crean dentro de una
transaccion que siempre se revierte.
