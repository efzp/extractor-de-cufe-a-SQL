$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sender = Join-Path $repositoryRoot 'scripts/Enviar-ReintentosCertificadoDian.ps1'
$sql = Join-Path $repositoryRoot 'scripts/Preparar-ReintentosCertificadoDian.sql'
$temporaryFile = New-TemporaryFile
$resultsPath = $temporaryFile.FullName

try {
    $sqlText = Get-Content -LiteralPath $sql -Raw
    if ($sqlText -notmatch '@ConfirmarEjecucion bit = 0') {
        throw 'El SQL debe estar bloqueado por defecto.'
    }
    $targetList = [regex]::Match(
        $sqlText,
        '(?s)INSERT INTO @Objetivos.*?VALUES\s*(.*?);'
    ).Groups[1].Value
    $targetMatches = [regex]::Matches($targetList, '\((\d+),\s*(\d+),\s*(\d+)\)')
    if ($targetMatches.Count -ne 22) {
        throw 'El SQL no contiene exactamente 22 objetivos.'
    }

    $consultations = @{
        '12' = 9;  '13' = 10; '14' = 11
        '16' = 23; '17' = 19; '18' = 13
        '19' = 15; '20' = 12; '21' = 18
        '22' = 20; '23' = 17; '24' = 25
        '25' = 21; '26' = 31; '27' = 26
        '28' = 27; '29' = 28; '30' = 29
        '31' = 30; '32' = 16; '33' = 22
        '34' = 24
    }
    $seenTargets = @{}
    foreach ($target in $targetMatches) {
        $id = [int]$target.Groups[1].Value
        $versionId = [int]$target.Groups[2].Value
        $consultationId = [int]$target.Groups[3].Value
        if ($seenTargets.ContainsKey([string]$id) -or
            -not $consultations.ContainsKey([string]$id) -or
            $versionId -ne ($id - 1) -or
            $consultationId -ne $consultations[[string]$id]) {
            throw "Objetivo SQL incorrecto o duplicado para el documento $id."
        }
        $seenTargets[[string]$id] = $true
    }
    $rows = @(
        foreach ($id in ($consultations.Keys | ForEach-Object { [int]$_ } | Sort-Object)) {
            $payload = [ordered]@{
                schemaVersion = 1
                correlationId = [string][guid]::NewGuid()
                clienteId = 9
                cargaArchivoId = 8
                documentoId = $id
                documentoVersionId = $id - 1
                tipoClave = 'CUDE'
                claveDocumento = 'a' * 96
            }
            [pscustomobject]@{
                DocumentoID = $id
                ConsultaDianID = $consultations[[string]$id]
                MensajeParaCola = $payload | ConvertTo-Json -Compress
            }
        }
    )

    $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultsPath -Encoding UTF8
    $null = & $sender -ResultsPath $resultsPath

    $rows[0].MensajeParaCola = '{"MensajeParaCola":"no es el mensaje interior"}'
    $rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultsPath -Encoding UTF8
    $rejected = $false
    try {
        $null = & $sender -ResultsPath $resultsPath
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw 'El envio acepto indebidamente un JSON envuelto.'
    }

    Write-Host 'OK: 22 mensajes validos; JSON envuelto rechazado; SQL bloqueado por defecto.'
}
finally {
    Remove-Item -LiteralPath $resultsPath -ErrorAction SilentlyContinue
}
