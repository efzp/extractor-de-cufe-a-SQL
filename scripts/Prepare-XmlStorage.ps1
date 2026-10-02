param(
    [Parameter(Mandatory = $true)]
    [string] $StorageAccount,

    [Parameter(Mandatory = $true)]
    [string] $StorageResourceGroup,

    [Parameter(Mandatory = $true)]
    [string] $FunctionName,

    [Parameter(Mandatory = $true)]
    [string] $FunctionResourceGroup
)

$ErrorActionPreference = 'Stop'
$containerName = 'xml-dian'
$blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

foreach ($entry in @(
    @{ Name = 'StorageAccount'; Value = $StorageAccount },
    @{ Name = 'StorageResourceGroup'; Value = $StorageResourceGroup },
    @{ Name = 'FunctionName'; Value = $FunctionName },
    @{ Name = 'FunctionResourceGroup'; Value = $FunctionResourceGroup }
)) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        throw "Falta el parámetro $($entry.Name)."
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $response = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Falló Azure CLI en: az $($Arguments[0..1] -join ' ')."
    }
    if (-not $response) {
        return $null
    }
    return ($response | Out-String | ConvertFrom-Json)
}

$subscriptionId = Invoke-AzJson @('account', 'show', '--query', 'id')
$storageId = Invoke-AzJson @(
    'storage', 'account', 'show', '--name', $StorageAccount,
    '--resource-group', $StorageResourceGroup, '--query', 'id'
)
$functionId = Invoke-AzJson @(
    'functionapp', 'show', '--name', $FunctionName,
    '--resource-group', $FunctionResourceGroup, '--query', 'id'
)
$principalId = Invoke-AzJson @(
    'functionapp', 'identity', 'show', '--ids', $functionId,
    '--query', 'principalId'
)

if ([string]::IsNullOrWhiteSpace($storageId) -or
    -not $storageId.StartsWith("/subscriptions/$subscriptionId/", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'La cuenta de Storage no pertenece a la suscripción autenticada.'
}
if ([string]::IsNullOrWhiteSpace($functionId) -or
    -not $functionId.StartsWith("/subscriptions/$subscriptionId/", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'La Function no pertenece a la suscripción autenticada.'
}
if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'La Function no tiene identidad administrada asignada por el sistema.'
}

$containerScope = "$storageId/blobServices/default/containers/$containerName"
$existence = Invoke-AzJson @(
    'storage', 'container-rm', 'exists', '--storage-account', $storageId,
    '--name', $containerName
)
if ($null -eq $existence -or $existence.exists -isnot [bool]) {
    throw 'Azure CLI no devolvió el estado de existencia del contenedor.'
}

if (-not $existence.exists) {
    $null = Invoke-AzJson @(
        'storage', 'container-rm', 'create', '--storage-account', $storageId,
        '--name', $containerName, '--public-access', 'off'
    )
    Write-Host "Contenedor privado $containerName creado."
}
else {
    Write-Host "El contenedor $containerName ya existe."
}

$container = Invoke-AzJson @('storage', 'container-rm', 'show', '--ids', $containerScope)
$publicAccess = $container.publicAccess
if ($null -eq $publicAccess -and $null -ne $container.properties) {
    $publicAccess = $container.properties.publicAccess
}
if ($null -ne $publicAccess -and
    [string]$publicAccess -notin @('', 'None', 'Off')) {
    throw "El contenedor $containerName permite acceso público; revise su configuración antes de desplegar."
}

$assignments = @(Invoke-AzJson @(
    'role', 'assignment', 'list', '--scope', $containerScope,
    '--include-inherited'
))
$roleSuffix = "/roleDefinitions/$blobContributorRoleId"
$existingRole = $assignments | Where-Object {
    $_.principalId -eq $principalId -and
    $null -ne $_.roleDefinitionId -and
    $_.roleDefinitionId.EndsWith($roleSuffix, [StringComparison]::OrdinalIgnoreCase)
}

if (-not $existingRole) {
    $null = Invoke-AzJson @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', $blobContributorRoleId,
        '--scope', $containerScope
    )
    Write-Host 'Rol Storage Blob Data Contributor asignado a la identidad de la Function en xml-dian.'
}
else {
    Write-Host 'La identidad de la Function ya dispone del rol Storage Blob Data Contributor.'
}

Write-Host 'Preparación de xml-dian completada. La propagación de RBAC puede tardar varios minutos.'
