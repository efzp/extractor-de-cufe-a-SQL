# Esquema SQL DIAN

Azure SQL es la fuente de verdad de las cargas y documentos DIAN. La Function
usa identidad administrada y solo recibe `EXECUTE` sobre procedimientos
autorizados; no se conceden permisos generales sobre las tablas.

## Contabilidad historica (ampliacion 004)

Ejecutar primero `migrations/004_contabilidad_historica.sql` una sola vez en
`sqldb-dian-xml-cpabaas-dev`. Crea el esquema `contabilidad` y las tablas
`CargaArchivo`, `MovimientoHistorico` y `CargaMovimiento` sin tocar los datos
DIAN. Despues, en el editor web de Azure SQL, pegar y ejecutar una sola vez
`../scripts/Instalar-ProcedimientosContables.sql` (sin `GO`). El archivo se
regenera desde los tres procedimientos fuente y los permisos con
`../scripts/Generar-InstalacionProcedimientosContables.py`.

Como alternativa, ejecutar **por separado** cada archivo `CREATE OR ALTER
PROCEDURE`, en este orden:

1. `procedures/sp_IniciarCargaContable.sql`
2. `procedures/sp_RegistrarMovimientoContable.sql`
3. `procedures/sp_FinalizarCargaContable.sql`
4. `security/contabilidad_runtime_grants.sql`

No combinar la alternativa con el instalador unico. `CREATE OR ALTER PROCEDURE` debe comenzar su propio lote. El script de
permisos concede solo `EXECUTE` al rol existente `dian_runtime`. La prueba
`tests/test_ContabilidadHistorica.sql` crea datos dentro de una transaccion
que siempre revierte; ejecutarla despues de instalar los procedimientos.

El registro recibe `FilaJson` con las claves PascalCase de
`MovimientoHistorico` (por ejemplo, `Fecha`, `TipoDoc`, `IndContabilidad`,
`Debito`, `Credito`). La Function debe convertir `FECHA` a `aaaa-mm-dd`,
`FECHA_SISTEMA` a ISO 8601 sin zona, los importes a decimal con punto y los
identificadores a texto. `NumeroMovil` es opcional en el formato antiguo.
SQL calcula `HashContenidoSha256` version 1 sobre un JSON de valores
normalizados de `Fecha`, `Documento`, `TipoDoc`, `NumDoc`, `Cuenta`, `Concepto`,
`Naturaleza`, `Centro`, `CC`, `Debito`, `Credito`, `IdentidadTercero` y
`DocFuente`, en ese orden, codificado como UTF-16LE. El hash no es unico.

La primera fila de cada `(ClienteID, FuenteContable, IndContabilidad)` se
conserva. Si vuelve con el mismo hash, la fila de carga queda `DUPLICADO`;
si cambia el hash, queda `ID_CON_CONTENIDO_DISTINTO` sin actualizar la
contabilidad historica. Un ID nuevo se inserta aun si el rango de fechas ya
se habia cargado. El SHA-256 del XLSX, dentro del mismo cliente y fuente,
impide procesar dos veces los mismos bytes.

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

## Extracción tabular de XML (ampliación 003)

Para el editor web de Azure SQL, se puede pegar y ejecutar **una sola vez** el
contenido completo de `scripts/Instalar-ExtraccionXmlDian.sql`. No contiene
`GO`: instala las tres tablas, cuatro procedimientos, permisos y vista en una
transacción y devuelve `TablasExtraccion=3`, `ProcedimientosExtraccion=4`,
`VistasExtraccion=1`. No combinarlo con los pasos individuales de abajo.
El script se genera desde los archivos fuente mediante
`scripts/Generar-InstalacionExtraccionXmlDian.py`; `--check` detecta si quedó
desactualizado tras editar una fuente.

En la base actual, ejecutar `migrations/003_xml_extraction.sql` antes de
desplegar el código nuevo. Luego ejecutar **cada** archivo siguiente por
separado si no se usa el script integrado (un `CREATE OR ALTER PROCEDURE` debe
iniciar su lote):

1. `procedures/sp_ObtenerXmlParaExtraccion.sql`
2. `procedures/sp_ListarXmlPendientesExtraccion.sql`
3. `procedures/sp_RegistrarExtraccionXml.sql`
4. `procedures/sp_RegistrarErrorExtraccionXml.sql`
5. `security/dian_xml_extraction_grants.sql`
6. `views/vw_FacturaXmlMlV1.sql` (también en lote separado)

No ejecutar de nuevo `scripts/Recrear-EsquemaDian.sql`: solo recrea la línea
base vacía y no es una migración para la base con datos. La ampliación conserva
`DocumentoXml`, `Documento` y sus datos existentes. `dian_runtime` no recibe
acceso directo a tablas ni a la vista ML.

Configurar `DIAN_XML_EXTRACTION_QUEUE_NAME=xml-extraccion-pendiente` y crear
esa cola en el mismo Storage Account usado por `DianStorage`. Cada cinco
minutos `ProgramarExtraccionXmlDian` consulta hasta 100 XML vigentes no
extraídos y los encola; `ExtraerXmlDian` procesa el mensaje con
`documentoXmlId`. Esto también recupera los XML históricos, sin descargarlos
otra vez de la DIAN. Los duplicados de cola no duplican registros.

Un XML que falla validaciones permanentes queda en `XmlExtraccionError` y no
se publica en `vw_FacturaXmlMlV1` ni cambia a `PROCESADO`. Una falla transitoria
de Blob o SQL deja fallar la Function para que Azure Queue aplique sus
reintentos. Para reprocesar tras corregir la causa, un administrador debe
retirar la fila concreta de `XmlExtraccionError`; no borrar el Blob ni la carga.

Consulta de control (solo lectura):

```sql
SELECT x.DocumentoXmlID, d.DocumentoID, d.ClaveDocumento, d.EstadoProceso,
       e.VersionExtractor, e.CantidadLineas, err.Codigo, err.Detalle
FROM dian.DocumentoXml AS x
JOIN dian.Documento AS d ON d.DocumentoID = x.DocumentoID
LEFT JOIN dian.XmlExtraccion AS e ON e.DocumentoXmlID = x.DocumentoXmlID
LEFT JOIN dian.XmlExtraccionError AS err ON err.DocumentoXmlID = x.DocumentoXmlID
WHERE x.EsVigente = 1
ORDER BY x.DocumentoXmlID;
```

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
