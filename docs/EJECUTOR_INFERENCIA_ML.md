# Ejecutor de inferencia ML (Blob -> Azure SQL)

`scripts/ejecutar_inferencia_blob_sql.py` es el punto de entrada del job. El
artefacto AutoGluon **no** se incorpora a la imagen: se descarga de
`stdianxmlcpabaasdev/modelos-ml`, se verifican los SHA-256 del paquete y del
manifiesto, y se descarta al terminar. El proceso usa `DefaultAzureCredential`:
`az login` en el PC o la identidad administrada asignada al job en Azure.

## Comportamiento

- Sin `--publicar`: consulta, transforma y calcula el top 3, pero no escribe SQL.
- Con `--xml-ids 470,471,484`: procesa solo esos XML y permite comprobar
  `YA_EXISTE` al repetir la publicacion.
- Sin `--xml-ids`: toma primero los `DocumentoXmlID` mas recientes, hasta `--limite` facturas
  `Invoice` de `ml.vw_FacturaOrigenMlV1`, fuera del dataset de entrenamiento y
  sin prediccion para el SHA-256 del modelo. `--limite` es 3 por defecto y 100
  como maximo por ejecucion.
- Cada llamada a `ml.sp_RegistrarPrediccionPlantilla` confirma una factura.
  Si el proceso falla, las anteriores quedan registradas y el siguiente lote
  puede continuar. El procedimiento mantiene la idempotencia ante carreras.
- `SIN_PENDIENTES` es un resultado normal, no un error.

No genera lineas ni importes de Helisa; publica solamente el top 3 de
plantillas para revision.

## Prueba local desde cualquier directorio de PowerShell

```powershell
$repo = 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN'
$env:DIAN_SQL_SERVER = 'sql-dian-xml-cpabaas-dev.database.windows.net'
$env:DIAN_SQL_DATABASE = 'sqldb-dian-xml-cpabaas-dev'

# Solo lectura. Requiere az login y el entorno .venv-ml ya instalado.
& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\ejecutar_inferencia_blob_sql.py" `
  --xml-ids '470,471,484'

# Cuando el resultado anterior sea correcto, esta prueba reintenta esas
# predicciones ya existentes: deben devolver YA_EXISTE, sin duplicar filas.
& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\ejecutar_inferencia_blob_sql.py" `
  --xml-ids '470,471,484' --publicar
```

Para procesar nuevas facturas, omitir `--xml-ids`. Comenzar con `--limite 3`
sin `--publicar`, revisar el top 3 y despues repetir con `--publicar`. Una
ejecucion posterior tomara las siguientes pendientes.

## Imagen del job

El contexto de Docker debe ser la raiz del repositorio; el Dockerfile es
`docker/ml-inference-job.Dockerfile`. Instala ODBC Driver 18 para Azure SQL y
las versiones de bibliotecas usadas por el artefacto. La imagen usa PyTorch CPU,
no las bibliotecas CUDA de entrenamiento. El comando predeterminado
de la imagen hace **solo validacion** de hasta tres facturas. La configuracion
del job debera incluir `--limite 3 --publicar` como argumentos explicitamente
cuando se autorice a escribir.

Antes de desplegar, construir y probar la imagen en Linux contra el entorno
dev. No se ha creado ACR ni Container Apps Job mediante este cambio.

## Permisos de la identidad administrada del job

- Storage Blob Data Reader sobre el contenedor `modelos-ml`.
- `AcrPull` sobre el registro que contenga la imagen.
- En `sqldb-dian-xml-cpabaas-dev`, crear un usuario de Entra para esa identidad
  y conceder `SELECT` en `ml.vw_FacturaOrigenMlV1`, `ml.DatasetFila` y
  `ml.PrediccionPlantilla`, y `EXECUTE` en
  `ml.sp_RegistrarPrediccionPlantilla`. Las lecturas directas son necesarias
  para seleccionar pendientes; el procedimiento valida y registra cada fila.
- Verificar conectividad de red desde Container Apps a Azure SQL y a Blob.

No conceder permisos de escritura directa sobre las tablas ML.
