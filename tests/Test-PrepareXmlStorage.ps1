$ErrorActionPreference = 'Stop'
$global:Scenario = 'create'
$global:AzCalls = [System.Collections.Generic.List[string]]::new()

function global:az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $CliArguments)

    $global:AzCalls.Add(($CliArguments -join ' '))
    $global:LASTEXITCODE = 0
    $command = $CliArguments[0..2] -join ' '
    switch -Regex ($command) {
        '^account show ' {
            '"sub"'
            return
        }
        '^storage account show$' {
            '"/subscriptions/sub/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/storage"'
            return
        }
        '^functionapp show ' {
            '"/subscriptions/sub/resourceGroups/rg-function/providers/Microsoft.Web/sites/function"'
            return
        }
        '^functionapp identity show$' {
            '"11111111-1111-1111-1111-111111111111"'
            return
        }
        '^storage container-rm exists$' {
            if ($global:Scenario -eq 'create') { '{"exists":false}' }
            else { '{"exists":true}' }
            return
        }
        '^storage container-rm create$' {
            '{}'
            return
        }
        '^storage container-rm show$' {
            if ($global:Scenario -eq 'public') {
                '{"publicAccess":"Blob"}'
            }
            else {
                '{"publicAccess":null}'
            }
            return
        }
        '^role assignment list$' {
            if ($global:Scenario -eq 'create') {
                '[]'
            }
            else {
                '[{"principalId":"11111111-1111-1111-1111-111111111111","roleDefinitionId":"/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"}]'
            }
            return
        }
        '^role assignment create$' {
            '{}'
            return
        }
        default {
            throw "Comando Azure inesperado en la prueba: $command"
        }
    }
}

$preparationScript = Join-Path $PSScriptRoot '../scripts/Prepare-XmlStorage.ps1'
foreach ($scenario in @('create', 'existing')) {
    $global:Scenario = $scenario
    $global:AzCalls.Clear()
    & $preparationScript `
        -StorageAccount 'storage' `
        -StorageResourceGroup 'rg-storage' `
        -FunctionName 'function' `
        -FunctionResourceGroup 'rg-function'

    $containerCreates = @($global:AzCalls | Where-Object {
        $_ -like 'storage container-rm create *'
    })
    $roleCreates = @($global:AzCalls | Where-Object {
        $_ -like 'role assignment create *'
    })
    $expectedCreates = if ($scenario -eq 'create') { 1 } else { 0 }
    if ($containerCreates.Count -ne $expectedCreates -or
        $roleCreates.Count -ne $expectedCreates) {
        throw "La preparación no es idempotente en el escenario $scenario."
    }
    if (@($global:AzCalls | Where-Object { $_ -match ' delete ' }).Count -gt 0) {
        throw 'La preparación intentó eliminar un recurso.'
    }
}

$global:Scenario = 'public'
$global:AzCalls.Clear()
try {
    & $preparationScript `
        -StorageAccount 'storage' `
        -StorageResourceGroup 'rg-storage' `
        -FunctionName 'function' `
        -FunctionResourceGroup 'rg-function'
    throw 'La preparación aceptó un contenedor público.'
}
catch {
    if ($_.Exception.Message -notlike '*permite acceso público*') {
        throw
    }
}
if (@($global:AzCalls | Where-Object { $_ -like 'role assignment create *' }).Count -gt 0) {
    throw 'La preparación asignó un rol a un contenedor público.'
}

Remove-Item Function:\az
Remove-Variable AzCalls -Scope Global
Remove-Variable Scenario -Scope Global
Write-Host 'Pruebas locales de preparación de Storage: OK'
