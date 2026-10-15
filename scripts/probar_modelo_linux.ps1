param(
    [string]$Paquete = 'C:\modelos_autogluon\publicacion\modelo-dataset-v1-20261014T161302Z_e0d0db9a.tar.gz',
    [string]$Manifiesto = 'C:\modelos_autogluon\comparacion-oversampling\dataset_v1_20261014T161302Z_e0d0db9a\manifiesto.json',
    [string]$ReferenciaDir = 'C:\modelos_autogluon\inferencia-validacion\inferencia_20261014T235413Z_de5d3551',
    [string]$Imagen = 'dian-ml-smoke:local'
)

$ErrorActionPreference = 'Stop'
$repoPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$paquetePath = (Resolve-Path -LiteralPath $Paquete).Path
$manifiestoPath = (Resolve-Path -LiteralPath $Manifiesto).Path
$referenciaPath = (Resolve-Path -LiteralPath $ReferenciaDir).Path

docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop debe estar iniciado y configurado para contenedores Linux.'
}

Push-Location -LiteralPath $repoPath
try {
    docker build --platform linux/amd64 -f docker/ml-smoke.Dockerfile -t $Imagen .
    if ($LASTEXITCODE -ne 0) { throw 'Fallo la construccion de la imagen Linux.' }

    docker run --rm --platform linux/amd64 --memory 8g `
        --mount "type=bind,source=$paquetePath,target=/input/modelo.tar.gz,readonly" `
        --mount "type=bind,source=$manifiestoPath,target=/input/manifiesto.json,readonly" `
        --mount "type=bind,source=$referenciaPath,target=/input/referencia,readonly" `
        $Imagen
    if ($LASTEXITCODE -ne 0) { throw 'La prueba Linux fallo; no desplegar el modelo.' }
}
finally {
    Pop-Location
}
