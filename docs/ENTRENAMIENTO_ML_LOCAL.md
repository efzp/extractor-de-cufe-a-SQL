# Entrenamiento local a partir de Azure SQL

`scripts/entrenar_modelo_azure_sql.py` lee, sin modificar, una version publicada
en `ml.DatasetVersion` y `ml.DatasetFila`. No consulta el Blob ni vuelve a ejecutar
el matching. El identificador de version es obligatorio: nunca toma
automaticamente la version mas reciente.

El contrato SQL conserva 18 predictoras del pipeline historico, no todas las
columnas del XLSX antiguo. Por ello este entrenamiento conserva la etiqueta y
las reglas principales, pero el modelo resultante no es identico al anterior.

## Preparar el equipo

- Python 3.11 y ODBC Driver 18 for SQL Server.
- `az login` con un usuario que pueda consultar `ml.DatasetVersion` y
  `ml.DatasetFila`. La identidad de la Function App no concede permisos a tu
  usuario local.
- Un entorno **separado** del usado para desplegar Azure Functions. No agregar
  AutoGluon al `requirements.txt` de la Function App.

Desde cualquier carpeta de PowerShell:

```powershell
$repo = 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN'
$venv = Join-Path $repo '.venv-ml'
py -3.11 -m venv $venv
$python = Join-Path $venv 'Scripts\python.exe'
& $python -m pip install --upgrade pip
& $python -m pip install -r (Join-Path $repo 'requirements-ml-training.txt')
& $python -m pip check
```

Si AutoGluon ya esta instalado en otro entorno, se puede usar ese Python con
el mismo script. La instalacion no modifica Azure.

## Validar sin entrenar

```powershell
& $python (Join-Path $repo 'scripts\entrenar_modelo_azure_sql.py') `
  --dataset-version-id 1 `
  --servidor sql-dian-xml-cpabaas-dev.database.windows.net `
  --base sqldb-dian-xml-cpabaas-dev `
  --salida 'C:\modelos_autogluon' `
  --solo-validar
```

Esta opcion no necesita AutoGluon y no crea archivos. Comprueba conteos,
columnas, fechas, clases y particion. La corrida anterior de la version 1,
con la particion antigua del 20 % exacto, tenia 1.540 filas: 1.091 entrenables
y 308 en prueba; 92 de estas ultimas eran de clases no entrenadas. Con la
nueva reserva por meses completos los conteos cambian. El
`hash_lectura_sql_sha256` permite comprobar en una futura lectura que las
columnas consumidas de esa version siguen iguales.

## Entrenar y evaluar

Usar el mismo comando sin `--solo-validar`. Los valores predeterminados son:
minimo 2 observaciones por clase, dos copias en total de las facturas de los
12 meses calendario completos inmediatamente anteriores al mes de prueba,
preset `best_quality`, limite de 1.500 segundos y metrica `accuracy`. Por
ejemplo, si la prueba empieza en julio de 2026, se replica una vez el tramo
julio de 2025 a junio de 2026. Los meses mas antiguos conservan una sola copia.

La prueba reserva meses calendario completos por `FechaEmision`: comienza por
el mes mas reciente y retrocede hasta alcanzar el objetivo del 20 %, con un
limite predeterminado de 2 meses (`--max-meses-prueba 2`). Si esos dos meses no llegan al
20 %, prevalece el limite temporal y el porcentaje real sera menor; si un mes
completo supera el 20 %, no se divide. Por ejemplo, en la version 1 anterior,
julio-agosto de 2026 tienen 142 de 1.540 filas (9,2 %). El snapshot SQL no
incluye fecha de contabilizacion: **la particion usa fecha de emision de la
factura, no periodo contable**. No se duplican filas de prueba.

```powershell
& $python (Join-Path $repo 'scripts\entrenar_modelo_azure_sql.py') `
  --dataset-version-id 1 `
  --servidor sql-dian-xml-cpabaas-dev.database.windows.net `
  --base sqldb-dian-xml-cpabaas-dev `
  --salida 'C:\modelos_autogluon'
```

Cada corrida crea una subcarpeta nueva con `modelo/`, `manifiesto.json`,
`particion.csv`, `predicciones_prueba.csv` y `leaderboard_interno.csv`. El
manifiesto guarda los hashes de la version SQL, version del adaptador,
columnas, parametros, versiones de librerias y metricas externas. La ruta de
salida puede cambiarse; es preferible un disco local sin sincronizacion de
OneDrive, ya que AutoGluon puede producir muchos archivos.

`accuracy_prueba_total` cuenta tambien etiquetas no vistas en entrenamiento.
`accuracy_prueba_clases_conocidas` permite separar ese problema de la calidad
del clasificador, pero nunca debe presentarse como la exactitud global. El
resumen tambien incluye `accuracy_top3_prueba_total` y
`accuracy_top3_prueba_clases_conocidas`: la proporcion de facturas cuya
plantilla correcta figura entre las tres primeras opciones. `predicciones_prueba.csv`
incluye esas opciones, el acierto top-3 y la confianza de la primera.
`leaderboard_interno.csv` corresponde a la validacion interna de AutoGluon.
En un entrenamiento completo, "clase conocida" se determina con las clases
que el predictor realmente conserva (`clases_modelo`); en `--solo-validar` es
una estimacion basada en el filtro previo al entrenamiento.
El resumen indica `fraccion_prueba_objetivo`, `fraccion_prueba_real`,
`primer_mes_prueba` y `meses_prueba_reales` para auditar la particion.

Para contrastar el sobremuestreo reciente, ejecutar dos corridas con el mismo
`DatasetVersionID`, limite de tiempo y particion; la segunda agrega
`--sin-oversampling-reciente`. Comparar los valores de
`accuracy_prueba_total` y `accuracy_top3_prueba_total` de los manifiestos, no
los puntajes del leaderboard interno. Las corridas crean subcarpetas nuevas:
no sobrescriben el modelo previo.

Los archivos locales pueden contener identificadores de XML y plantillas
contables: mantener la carpeta privada y no subirla al repositorio.
