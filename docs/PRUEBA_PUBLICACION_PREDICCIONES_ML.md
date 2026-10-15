# Prueba acotada de publicacion ML

La prueba usa el modelo local confiable de `DatasetVersionID=1`, consulta los
`DocumentoXmlID` indicados, reconstruye las 18 variables y calcula el top 3.
`--publicar` llama a `ml.sp_RegistrarPrediccionPlantilla` dos veces por XML,
dentro de una transaccion. La segunda pasada debe devolver `YA_EXISTE` con
el mismo `PrediccionPlantillaID`. Si alguna comprobacion falla, se revierte
la transaccion. Sin `--publicar` no se escribe en SQL.

Desde cualquier directorio de PowerShell:

```powershell
$repo = 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN'
$modelo = 'C:\modelos_autogluon\comparacion-oversampling\dataset_v1_20261014T161302Z_e0d0db9a'
$paquete = 'C:\modelos_autogluon\publicacion\modelo-dataset-v1-20261014T161302Z_e0d0db9a.tar.gz'

& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\publicar_predicciones_azure_sql.py" `
  --modelo-dir $modelo --modelo-paquete $paquete `
  --xml-ids '471,470,484,486,485,482,481,480,479,478' `
  --servidor 'sql-dian-xml-cpabaas-dev.database.windows.net' `
  --base 'sqldb-dian-xml-cpabaas-dev'

# Agregar --publicar solo despues de revisar el resultado SOLO_VALIDACION.
```

El paquete local debe ser el mismo `.tar.gz` cargado al contenedor `modelos-ml`.
El script calcula su SHA-256, pero no consulta Blob Storage para verificar el
contenido remoto. No cargar artefactos pickle de procedencia desconocida.

Consulta de control (solo lectura):

```sql
SELECT COUNT(*) AS Total,
       SUM(CASE WHEN EstadoRevision = 'PENDIENTE' THEN 1 ELSE 0 END) AS Pendientes,
       COUNT(DISTINCT DocumentoXmlID) AS XmlDistintos
FROM ml.PrediccionPlantilla
WHERE DocumentoXmlID IN (470,471,478,479,480,481,482,484,485,486)
  AND ModeloArtefactoSha256 =
      'b0dcb976fcd986317dde055d322555b805a504c48325a117b63c5fdf90dac4a3';
```
