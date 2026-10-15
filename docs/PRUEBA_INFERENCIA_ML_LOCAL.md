# Prueba local de inferencia contra Azure SQL

El adaptador lee `ml.vw_FacturaOrigenMlV1`, excluye los `DocumentoXmlID` de
`ml.DatasetFila` usados por la version del modelo y reproduce el preprocesamiento
del dataset historico. No modifica Azure SQL, no descarga el modelo desde Blob y
no entrena de nuevo. Solo carga un artefacto local de confianza.

Desde PowerShell, incluso si estas en `C:\Windows\System32`:

```powershell
$env:DIAN_SQL_SERVER = "sql-dian-xml-cpabaas-dev.database.windows.net"
$env:DIAN_SQL_DATABASE = "sqldb-dian-xml-cpabaas-dev"
$repo = "C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN"
$modelo = "C:\modelos_autogluon\comparacion-oversampling\dataset_v1_20261014T161302Z_e0d0db9a"
$salida = "C:\modelos_autogluon\inferencia-validacion"

& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\probar_inferencia_azure_sql.py" `
  --modelo-dir $modelo --cliente-id 1 --limite 10 `
  --salida $salida --solo-validar

& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\probar_inferencia_azure_sql.py" `
  --modelo-dir $modelo --cliente-id 1 --limite 10 `
  --salida $salida
```

`--solo-validar` consulta SQL y prepara las 18 variables sin cargar AutoGluon ni
crear archivos. La segunda orden crea una subcarpeta con `predicciones_top3.csv`,
`variables_modelo.csv` y `resumen.json`. El CSV de variables permite auditar la
entrada efectiva al predictor. Estos archivos pueden contener informacion sensible;
no deben publicarse en el repositorio.

El adaptador exige las versiones Python, AutoGluon, pandas y NumPy registradas
en `manifiesto.json`. Usa autenticacion de Azure CLI para SQL; primero ejecuta
`az login` con la cuenta que tenga `SELECT` sobre la vista y el dataset. El
directorio indicado por `--modelo-dir` debe contener `modelo/` y
`manifiesto.json`. El modelo publicado en Blob no se usa directamente en esta
prueba local.

Las predicciones no son una metrica de accuracy: las facturas seleccionadas no
tienen etiqueta contable conocida en el dataset de entrenamiento.
