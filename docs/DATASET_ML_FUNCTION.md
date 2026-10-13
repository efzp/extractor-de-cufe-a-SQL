# Generacion automatica del dataset ML v1

La funcion no entrena un modelo. Lee la vista `ml.vw_FacturaOrigenMlV1` y
`contabilidad.MovimientoHistorico`, ejecuta una copia fija del matching historico,
selecciona las facturas `OK_UNICO`, `OK_TEXTO` y `OK_VALOR` con etiqueta, y llama
`ml.sp_PublicarDatasetEntrenamientoV1`. Una segunda ejecucion con las mismas
entradas y el mismo resultado devuelve `YA_EXISTE`.

## Configuracion de la Function App

- `DIAN_SQL_SERVER`, `DIAN_SQL_DATABASE`, `DIAN_SQL_DRIVER` (opcional, por
  defecto `ODBC Driver 18 for SQL Server`) y `DIAN_STORAGE_ACCOUNT`: existentes
  en la instalacion de ingesta.
- `ML_DATASET_QUEUE_NAME=ml-datasets-pendientes`: crear la cola en la misma
  cuenta de Storage antes de desplegar.
- `ML_DATASET_ENABLED=false`: dejar desactivado hasta validar la prueba manual.
  Para ejecucion diaria, cambiar a `true` y configurar
  `ML_DATASET_CLIENTE_ID=1` y `ML_DATASET_FUENTE_CONTABLE=ERP_CPA_BAAS`.
  El programador se ejecuta a las 03:00 UTC. No usa Power Automate.
- `DianStorage` debe apuntar a la cuenta de Storage para el queue trigger,
  como las otras funciones de este proyecto.

La identidad administrada de la Function App necesita su rol de colaborador
de datos de Queue Storage en esa cuenta. En Azure SQL
necesita `SELECT` sobre `ml.vw_FacturaOrigenMlV1` y
`contabilidad.MovimientoHistorico`, y `EXECUTE` sobre
`ml.sp_PublicarDatasetEntrenamientoV1`. Conceder estos permisos al usuario de
base de datos que representa la identidad de la Function App; no se requiere
`INSERT` directo en las tablas ML.

## Prueba manual

Enviar `POST` a `/api/ml/datasets/1` con la clave de la funcion y cuerpo JSON:

```json
{"fuenteContable":"ERP_CPA_BAAS"}
```

La respuesta `202 ACCEPTED` solo confirma el encolado. Revisar la ejecucion de
`GenerarDatasetEntrenamiento` en Application Insights y despues consultar:

```sql
SELECT TOP (10) DatasetVersionID, ClienteID, FuenteContable,
       TotalFacturasOrigen, TotalFilas, FechaCreacionUTC
FROM ml.DatasetVersion
ORDER BY DatasetVersionID DESC;

SELECT DatasetVersionID, COUNT(*) AS Filas
FROM ml.DatasetFila
GROUP BY DatasetVersionID
ORDER BY DatasetVersionID DESC;
```

El procedimiento acepta una version solo si cada fila corresponde a un XML
Invoice vigente y procesado. El dataset es una instantanea: no se actualiza en
sitio cuando llegan nuevos XML o movimientos. La siguiente ejecucion crea otra
version. El hash de codigo incluye el motor empaquetado, el adaptador y las
versiones de Python, pandas, NumPy y openpyxl. Los otros hash identifican las
filas leidas; ninguno demuestra exactitud del match. La funcion falla si no
hay facturas, movimientos FC o si aparecen llaves de factura duplicadas.

## Despliegue

`requirements.txt` incluye pandas y NumPy, y `ml_dataset/legacy` contiene la
copia fija del motor usado por el adaptador de validacion. El flujo CI compila
este paquete y ejecuta las pruebas. `host.json` permite hasta 10 minutos por
ejecucion; si el volumen supera ese tiempo, habra que particionar el trabajo o
usar un plan con mayor capacidad. No activar el temporizador hasta confirmar
que el rol SQL y la cola estan disponibles y que la prueba manual devuelve
`PUBLICADA` o `YA_EXISTE`.
