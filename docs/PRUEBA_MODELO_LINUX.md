# Prueba local del modelo en contenedor Linux

Esta prueba no consulta Azure SQL, no publica predicciones y no escribe en Blob. Usa el paquete ya publicado y las diez facturas de la inferencia local de referencia. Verifica los SHA-256, el manifiesto, la limpieza historica (18 variables) y la coincidencia de las 30 opciones top 3 y sus probabilidades.

1. Inicia Docker Desktop en modo **Linux containers**.
2. En cualquier directorio de PowerShell, ejecuta:

```powershell
$repo = 'C:\Users\eduar\OneDrive - TCP BAAS S.A.S\Documentos\CPABAAS\Automatizacion XML CUFE DIAN'
& "$repo\scripts\probar_modelo_linux.ps1"
```

La primera construccion descargara la imagen de Python e instalara AutoGluon; puede tardar. Un resultado valido contiene `"resultado": "OK_OFFLINE_SIN_SQL"`, `"plataforma": "Linux"`, `"facturas_referencia": 10` y `"opciones_top3_verificadas": 30`. Si falla cualquier comparacion, el comando termina con error y no debe desplegarse ese modelo.

Las rutas del paquete, manifiesto y carpeta de referencia son parametros opcionales `-Paquete`, `-Manifiesto` y `-ReferenciaDir`. El SHA-256 esperado del paquete esta fijado en `docker/ml-smoke.Dockerfile`; para probar otro artefacto, actualizar tambien ese valor y las versiones de `requirements-ml-smoke.txt` segun su manifiesto.

La coincidencia de predicciones no mide accuracy: prueba compatibilidad del artefacto entre el entorno local y Linux. Esta prueba tampoco demuestra aun conectividad o permisos de una futura Azure Container Apps Job.
