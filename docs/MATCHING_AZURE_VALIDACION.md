# Validacion del match historico con Azure SQL

`scripts/validar_match_azure_sql.py` ejecuta, sin modificarlas, las funciones de
`procesamiento_facturas_contabilidad_match.py` sobre datos de Azure SQL. Solo
consulta la base; no registra matches ni entrena el modelo.

## Requisitos

- Python 3.11, ODBC Driver 18 for SQL Server y los paquetes de
  `requirements-matching.txt`.
- Sesion de Azure disponible para `DefaultAzureCredential` (por ejemplo,
  `az login`). La identidad debe tener `SELECT` sobre
  `dian.vw_FacturaXmlMlV1`, `dian.Documento`, `dian.CargaDocumento` y
  `contabilidad.MovimientoHistorico`. El rol de ejecucion de procedimientos
  `dian_runtime` no concede automaticamente estos permisos de lectura.
- Los dos scripts historicos en la misma carpeta, sin necesidad de importar
  `run_pipeline.py` ni `predictor de facturas XML.py`.

## Ejecucion local

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-matching.txt
$env:DIAN_SQL_SERVER = "<servidor>.database.windows.net"
$env:DIAN_SQL_DATABASE = "sqldb-dian-xml-cpabaas-dev"

.\.venv\Scripts\python.exe .\scripts\validar_match_azure_sql.py `
  --scripts-historicos 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Automatización' `
  --cliente-id 1 `
  --fuente-contable ERP_CPA_BAAS `
  --carga-dian-id 4 `
  --salida '.\salidas\match-validacion'
```

`--carga-dian-id` es opcional. Si se omite, usa todas las facturas `Invoice`
vigentes y procesadas del cliente. Incluso al filtrar facturas por carga, lee
**todos** los movimientos de la fuente contable: un asiento historico puede
provenir de otra carga o cubrir un periodo distinto.

Para comparar con un resultado anterior del mismo alcance, agregue
`--referencia '<ruta>\match_factura_asiento.xlsx'`. La comparacion usa
`llave_factura` para cotejar `estado_match` y `llave_asiento`; una diferencia
entre archivos de periodos distintos no demuestra una regresion del algoritmo.

Cada ejecucion crea una carpeta nueva con:

- `resumen.json`: volumen, periodos, estados, cobertura y hashes SHA-256 de los
  dos scripts historicos utilizados.
- `matches.xlsx`: una fila por factura, con CUFE, estado, asiento, puntaje y
  plantilla de cuentas cuando exista.
- `comparacion_referencia.xlsx`: solo si se proporciono `--referencia`.

Los XLSX contienen datos contables y de proveedores: mantengalos en una
ubicacion privada. La cobertura es la proporcion de facturas con estado
`OK_UNICO`, `OK_TEXTO` u `OK_VALOR`; no mide por si sola la precision del match.
Si dos CUFE producen la misma `llave_factura`, la validacion se detiene para
evitar reportar una cobertura engañosa.

El adaptador usa libros temporales para pasar los datos SQL al lector Excel
original y los elimina al finalizar. Por ello conserva la normalizacion, el
filtro de movimientos `FC`, la agrupacion por asiento y los umbrales de
matching existentes. No incorpora las descripciones de lineas XML de la
carpeta historica `XML definitivos`; esas descripciones no participan en la
decision del match, pero si pueden afectar variables de un entrenamiento
posterior.
