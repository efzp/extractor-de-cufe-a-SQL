param(
    [Parameter(Mandatory = $true)]
    [string] $ResultsPath,

    [switch] $Enviar
)

$ErrorActionPreference = 'Stop'
$storageAccount = 'stdianxmlcpabaasdev'
$storageResourceGroup = 'rg-dian-xml-cpabaas-dev'
$subscriptionId = '9b86c2e0-846c-4a39-badc-30d7f511c77d'
$queueName = 'documentos-pendientes'
$loadId = 8
$clientId = 9
$expectedConsultations = @{
    '12' = 9;  '13' = 10; '14' = 11
    '16' = 23; '17' = 19; '18' = 13
    '19' = 15; '20' = 12; '21' = 18
    '22' = 20; '23' = 17; '24' = 25
    '25' = 21; '26' = 31; '27' = 26
    '28' = 27; '29' = 28; '30' = 29
    '31' = 30; '32' = 16; '33' = 22
    '34' = 24
}

if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf)) {
    throw "No existe el archivo de resultados: $ResultsPath"
}

try {
    # En Windows PowerShell 5.1, ConvertFrom-Json en una tuberia puede entregar
    # el arreglo completo como un unico objeto. -InputObject conserva las filas.
    $rawJson = Get-Content -LiteralPath $ResultsPath -Raw -Encoding UTF8
    $parsedRows = ConvertFrom-Json -InputObject $rawJson
    $rows = @($parsedRows)
}
catch {
    throw 'El archivo no contiene JSON valido exportado del resultado del lote.'
}

if ($rows.Count -ne $expectedConsultations.Count) {
    throw "Se esperaban 22 resultados del lote y se recibieron $($rows.Count). No use el results.json del documento 15."
}

$messages = @()
$seenDocuments = @{}
$seenCorrelations = @{}
foreach ($row in $rows) {
    if ($null -eq $row.DocumentoID -or $null -eq $row.ConsultaDianID -or
        [string]::IsNullOrWhiteSpace([string]$row.MensajeParaCola)) {
        throw 'Una fila no tiene DocumentoID, ConsultaDianID y MensajeParaCola.'
    }

    $documentId = [int]$row.DocumentoID
    $documentKey = [string]$documentId
    if (-not $expectedConsultations.ContainsKey($documentKey)) {
        throw "El documento $documentId no pertenece a este lote."
    }
    if ($seenDocuments.ContainsKey($documentKey)) {
        throw "El documento $documentId aparece dos veces."
    }
    $seenDocuments[$documentKey] = $true
    if ([int]$row.ConsultaDianID -ne $expectedConsultations[$documentKey]) {
        throw "La consulta anterior del documento $documentId no coincide."
    }

    $messageText = [string]$row.MensajeParaCola
    try {
        $message = ConvertFrom-Json -InputObject $messageText
    }
    catch {
        throw "El mensaje interior del documento $documentId no es JSON valido."
    }
    if ($message -isnot [pscustomobject] -or
        $message.schemaVersion -isnot [ValueType] -or
        [int]$message.schemaVersion -ne 1) {
        throw "El documento $documentId no tiene schemaVersion numerico igual a 1."
    }
    foreach ($field in @('clienteId', 'cargaArchivoId', 'documentoId', 'documentoVersionId')) {
        if ($message.$field -isnot [ValueType]) {
            throw "El campo $field del documento $documentId debe ser numerico."
        }
    }
    if ([int]$message.clienteId -ne $clientId -or
        [int]$message.cargaArchivoId -ne $loadId -or
        [int]$message.documentoId -ne $documentId -or
        [int]$message.documentoVersionId -ne ($documentId - 1)) {
        throw "Los identificadores del mensaje del documento $documentId no coinciden."
    }
    if ($message.tipoClave -notin @('CUFE', 'CUDE') -or
        [string]$message.claveDocumento -cnotmatch '^[0-9a-f]{96}$') {
        throw "La clave del documento $documentId no cumple el contrato de la cola."
    }
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse([string]$message.correlationId, [ref]$parsedGuid)) {
        throw "El correlationId del documento $documentId no es un GUID."
    }
    if ($seenCorrelations.ContainsKey([string]$parsedGuid)) {
        throw "El correlationId del documento $documentId esta duplicado."
    }
    $seenCorrelations[[string]$parsedGuid] = $true

    $messages += [pscustomobject]@{
        DocumentoID = $documentId
        CorrelationID = [string]$parsedGuid
        Text = $messageText
    }
}

$messages = @($messages | Sort-Object DocumentoID)
Write-Host "Validacion local correcta: $($messages.Count) mensajes para $queueName."
Write-Host "Documentos: $(($messages.DocumentoID) -join ', ')."

if (-not $Enviar) {
    Write-Host 'No se envio nada. Use -Enviar solo despues de ejecutar y exportar el SQL de lote.'
    return
}

$receiptPath = "$ResultsPath.envios.jsonl"
if (Test-Path -LiteralPath $receiptPath) {
    throw "Ya existe un comprobante de envios: $receiptPath. No repita el lote sin revisar los mensajes enviados."
}

$activeSubscription = (& az account show --query id --output tsv --only-show-errors | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $activeSubscription -ne $subscriptionId) {
    throw 'Azure CLI no esta autenticado en la suscripcion esperada.'
}
$storageId = (& az storage account show --name $storageAccount `
    --resource-group $storageResourceGroup --query id --output tsv `
    --only-show-errors | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or
    $storageId -ne "/subscriptions/$subscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount") {
    throw 'No se pudo confirmar la cuenta de almacenamiento esperada.'
}

$confirmation = Read-Host 'Para enviar 22 mensajes escriba exactamente ENVIAR 22'
if ($confirmation -cne 'ENVIAR 22') {
    throw 'Envio cancelado: no se escribio la confirmacion exacta.'
}

# Crear el comprobante antes del primer envio: si no se puede escribir,
# no debe salir ningun mensaje. Su presencia bloquea una segunda ejecucion.
$batchReceipt = [pscustomobject]@{
    Tipo = 'LOTE_INICIADO'
    Cuenta = $storageAccount
    Cola = $queueName
    Cantidad = $messages.Count
    FechaUTC = [DateTime]::UtcNow.ToString('o')
}
Set-Content -LiteralPath $receiptPath -Value ($batchReceipt | ConvertTo-Json -Compress) -Encoding UTF8

foreach ($entry in $messages) {
    $null = & az storage message put `
        --account-name $storageAccount `
        --queue-name $queueName `
        --auth-mode login `
        --content $entry.Text `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Fallo el envio del documento $($entry.DocumentoID). Revise $receiptPath y la cola antes de cualquier reintento."
    }

    $receipt = [pscustomobject]@{
        DocumentoID = $entry.DocumentoID
        CorrelationID = $entry.CorrelationID
        FechaEnvioUTC = [DateTime]::UtcNow.ToString('o')
    }
    try {
        Add-Content -LiteralPath $receiptPath -Value ($receipt | ConvertTo-Json -Compress) -Encoding UTF8
    }
    catch {
        throw "El documento $($entry.DocumentoID) pudo ser enviado, pero fallo el comprobante. Inspeccione la cola y SQL antes de cualquier reintento."
    }
    Write-Host "Enviado documento $($entry.DocumentoID)."
}

Write-Host "Envio terminado. Comprobante: $receiptPath"
