# Prueba local Blob → modelo → Azure SQL

El script `scripts/probar_inferencia_blob_azure_sql.py` descarga el paquete publicado en `modelos-ml`, compara su SHA-256 con un valor fijado, verifica el manifiesto incluido y usa la vista SQL y el procedimiento de prediccion existentes. Solo admite 1–10 `DocumentoXmlID` explicitos. Sin `--publicar` no modifica SQL.

Desde cualquier directorio de PowerShell:

```powershell
$repo = 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN'
$env:DIAN_SQL_SERVER = 'sql-dian-xml-cpabaas-dev.database.windows.net'
$env:DIAN_SQL_DATABASE = 'sqldb-dian-xml-cpabaas-dev'

# Si falta el cliente de Blob en el entorno ML:
& "$repo\.venv-ml\Scripts\python.exe" -m pip install -r "$repo\requirements-ml-inference-local.txt"

# Validacion de solo lectura, con facturas ya conocidas:
& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\probar_inferencia_blob_azure_sql.py" `
  --xml-ids '470,471,484'
```

El resultado esperado es `SOLO_VALIDACION`, `filas_sql_escritas: 0`, el SHA-256 `b0dcb976fcd986317dde055d322555b805a504c48325a117b63c5fdf90dac4a3` y el `top3` de cada XML. La descarga usa la sesion de `az login`, no una clave de Storage.

Para probar la publicacion, selecciona primero un XML elegible **sin prediccion de este modelo** y ejecuta el mismo comando con un solo ID y `--publicar`. El script registra la prediccion dos veces en una transaccion; la segunda llamada debe devolver `YA_EXISTE`. Si falla, revierte la transaccion. La prueba del 15 de octubre de 2026 uso el XML 476: `PrediccionPlantillaID=11`, una fila `PENDIENTE`, segunda pasada `YA_EXISTE`.

```powershell
$xmlNuevo = '<DocumentoXmlID elegible y no publicado>'
& "$repo\.venv-ml\Scripts\python.exe" "$repo\scripts\probar_inferencia_blob_azure_sql.py" `
  --xml-ids $xmlNuevo --publicar
```

**Idempotencia entre ejecuciones:** las variables y las tres plantillas del modelo coincidieron, pero algunas probabilidades variaron alrededor de `0.00000006`. La version ajustada de `sql/procedures/sp_RegistrarPrediccionPlantilla.sql` acepta hasta `0.000001` de diferencia por probabilidad si todos los identificadores, hash y plantillas son identicos. No reescribe la fila existente. Diferencias mayores siguen produciendo `50917`. El contrato se aplico en la base dev el 15 de octubre de 2026; los XML 470, 471 y 484 devolvieron `YA_EXISTE` al repetir la prueba completa desde Blob.

El control de instalacion y la prueba de limites se pueden repetir con `scripts/actualizar_contrato_prediccion_plantilla.py`. Sin `--aplicar` solo comprueba la version; con `--aplicar` no vuelve a alterar el procedimiento si ya coincide con la fuente.

Esta prueba usa Azure CLI para autenticarse localmente. Un proceso futuro en Azure requerira identidad administrada y permisos propios para Blob y Azure SQL.
