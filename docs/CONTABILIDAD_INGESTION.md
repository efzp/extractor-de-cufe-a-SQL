# Ingesta de movimientos contables

La Function usa las tablas y procedimientos de `sql/migrations/004_contabilidad_historica.sql`
y `scripts/Instalar-ProcedimientosContables.sql`. No transforma XML ni modifica
el flujo DIAN de facturas.

## Preparacion de Azure

Crear en la misma cuenta `DIAN_STORAGE_ACCOUNT` el contenedor privado
`cargas-contabilidad` y la cola `contabilidad-cargas-pendientes`. La identidad
administrada de la Function necesita `Storage Blob Data Contributor` para el
contenedor y `Storage Queue Data Contributor` para la cola. El trigger usa la
conexion existente `DianStorage`; conservar `DianStorage__queueServiceUri`.
En SQL, la identidad debe pertenecer al rol `dian_runtime`, que tiene `EXECUTE`
sobre los tres procedimientos contables. No conceder permisos directos sobre
las tablas.

Configurar en la Function App:

| Variable | Valor predeterminado |
|---|---|
| `CONTABILIDAD_LOAD_CONTAINER` | `cargas-contabilidad` |
| `CONTABILIDAD_LOAD_QUEUE_NAME` | `contabilidad-cargas-pendientes` |
| `CONTABILIDAD_MAX_UPLOAD_BYTES` | `20971520` (20 MiB) |
| `CONTABILIDAD_MAX_ROWS` | `50000` |

Reutiliza `DIAN_STORAGE_ACCOUNT`, `DIAN_SQL_SERVER`, `DIAN_SQL_DATABASE`,
`DIAN_SQL_DRIVER` y `DianStorage__queueServiceUri`.
Aunque el codigo tenga un valor predeterminado, el App Setting
`CONTABILIDAD_LOAD_QUEUE_NAME` es obligatorio para que Azure Functions resuelva
el nombre de la cola en el trigger.

## Llamada desde Power Automate

`RecibirCargaContable` recibe el XLSX **binario** mediante:

```http
POST /api/contabilidad/cargas/{clienteId}?fuenteContable=ERP_CPA_BAAS&nombreArchivo=Movimiento%20contable.xlsx&nombreHoja=Sheet1
Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
x-functions-key: <clave de la Function>

<bytes del archivo>
```

En Power Automate, después del disparador de SharePoint, usar **Obtener
contenido del archivo** y pasar su contenido como cuerpo de HTTP. Construir
los valores de la URI con codificacion porcentual (`encodeUriComponent` para
el nombre y otros textos). `fuenteContable` debe ser un identificador estable
para el mismo sistema de origen, aunque los archivos solapen meses. No poner
el nombre del archivo ni otros textos con tildes en encabezados HTTP: estos
solo contienen `Content-Type` y la clave de la Function.

Se pueden agregar opcionalmente `sharePointItemId`, `sharePointUrl`, `etag` y
`cargadoPor` a la URI, codificados. `nombreHoja` es opcional; si se omite,
se usa la primera hoja con las columnas obligatorias. `NUMERO_MOVIL` también
es opcional. La respuesta `202` significa **encolado**, no terminado; incluye
`correlationId` para seguimiento.
No enviar vínculos de SharePoint con tokens de acceso como `sharePointUrl`,
porque los parámetros de la URI pueden quedar en registros HTTP.

`ProcesarCargaContable` descarga el XLSX desde Blob, calcula SHA-256,
normaliza fechas, importes e identificadores, llama a
`sp_IniciarCargaContable`, registra una fila por movimiento mediante
`sp_RegistrarMovimientoContable` y termina con `sp_FinalizarCargaContable`.
Las filas vacias se omiten. Una fila con datos invalidos queda `RECHAZADO`
en `contabilidad.CargaMovimiento`; no se descarta silenciosamente.
Si el mensaje de cola se repite, las filas ya registradas se reconocen por
`(CargaArchivoID, FilaOrigen)` y la carga `PROCESANDO` se puede reanudar.

Para revisar una carga:

```sql
SELECT TOP (20) CargaArchivoID, NombreArchivo, Estado, TotalFilas,
       FilasNuevas, FilasDuplicadas, FilasConflicto, FilasRechazadas,
       Mensaje, FechaInicioUTC, FechaFinUTC
FROM contabilidad.CargaArchivo
ORDER BY CargaArchivoID DESC;
```

Los errores permanentes de formato se entregan a la cola `-poison` tras los
reintentos definidos en `host.json`; revisar los logs y esa cola. El XLSX
original permanece en el contenedor para auditoria.
