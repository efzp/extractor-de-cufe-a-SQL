# Ingestión de listados XLSX de la DIAN

La ingestión se divide en dos Functions para que la solicitud de SharePoint no
espere mientras se procesan todas las filas.

## Recepción HTTP

`RecibirCargaDian` recibe el XLSX como cuerpo binario, lo almacena en el
contenedor `cargas-dian` y agrega un mensaje a `cargas-pendientes`.

```http
POST /api/dian/cargas/{clienteId}
Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
x-functions-key: <function-key>
x-file-name: listado-dian.xlsx
x-sharepoint-item-id: <opcional>
x-sharepoint-etag: <opcional>
x-sharepoint-url: <opcional>
x-table-name: <opcional>
x-uploaded-by: usuario@empresa.com

<bytes del XLSX>
```

La respuesta `202 Accepted` confirma almacenamiento y encolamiento, no la
terminación de la carga.

## Procesamiento por cola

`ProcesarCargaDian` se activa desde `cargas-pendientes` y realiza:

1. Descarga del XLSX desde Blob Storage.
2. Identificación de la primera tabla Excel o de `x-table-name`.
3. Normalización de las 32 columnas del reporte DIAN.
4. Cálculo SHA-256 del archivo, de cada fila y del contenido contable.
5. Ejecución de `dian.sp_IniciarCargaArchivo`.
6. Ejecución de `dian.sp_RegistrarDocumentoCarga` por cada fila.
7. Encolamiento de documentos nuevos en `documentos-pendientes`.
8. Ejecución de `dian.sp_FinalizarCargaArchivo`.

Las filas técnicas de Azure Queue se procesan de una en una. Si una ejecución
se repite, SQL reconoce las filas ya registradas. Los mensajes de descarga son
de entrega al menos una vez; el consumidor de `documentos-pendientes` también
debe validar el estado del documento antes de consultar la DIAN.

## Configuración

| Variable | Uso |
|---|---|
| `DIAN_STORAGE_ACCOUNT` | Nombre de la cuenta de almacenamiento |
| `DianStorage__queueServiceUri` | Conexión de identidad del Queue trigger |
| `DIAN_LOAD_CONTAINER` | Contenedor temporal de XLSX |
| `DIAN_LOAD_QUEUE_NAME` | Cola de archivos pendientes |
| `DIAN_QUEUE_NAME` | Cola de documentos pendientes de XML |
| `DIAN_SQL_SERVER` | Servidor lógico de Azure SQL |
| `DIAN_SQL_DATABASE` | Base de datos DIAN |
| `DIAN_SQL_DRIVER` | Controlador ODBC, por defecto versión 18 |
| `DIAN_MAX_UPLOAD_BYTES` | Tamaño máximo del XLSX, por defecto 20 MiB |

La Function obtiene tokens con Managed Identity. No utiliza usuarios ni
contraseñas SQL. La identidad requiere exclusivamente:

- `EXECUTE` mediante el rol SQL `dian_runtime`.
- `Storage Blob Data Contributor` sobre `cargas-dian`.
- `Storage Queue Data Contributor` sobre `cargas-pendientes` y
  `documentos-pendientes`.

El trigger usa el prefijo de conexión `DianStorage`, separado de
`AzureWebJobsStorage`. En Azure se configura con la URI del servicio de colas
y la identidad administrada de la Function.

## Estructura del lector

El lector utiliza las columnas del archivo real entregado por la DIAN,
incluidas las variantes de encabezados con caracteres dañados como
`Fecha Emisi�n`. Los valores originales se conservan como JSON en
`CargaDocumento.FilaOrigenJson`; la normalización no modifica el archivo.
