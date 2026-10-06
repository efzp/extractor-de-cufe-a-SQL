<#
Prueba local y de solo lectura del contrato XML DIAN v1.
Lee 34 XML de ejemplo y compara 33 campos reproducibles con el Excel historico.
id_carga no es reproducible: el flujo antiguo usaba la hora de ejecucion.
#>
param(
    [Parameter(Mandatory = $true)] [string] $XmlDirectory,
    [Parameter(Mandatory = $true)] [string] $WorkbookPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$prefixes = @(
    '0ffbe66', '1aa597c', '1ac46ef', '1aebdbb', '1b78a1a', '1ca4310',
    '1da7aeb', '1df3022', '1eed034', '1fd4d79', '2a17b4c', '2a38107',
    '2c0dc4a', '2d7770c', '2fa5f4b', '2fd2cfd', '3a9edea', '3be993d',
    '3ca9a79', '3d8b970', '3fb6149', '04ac092', '04b7cad', '04c4788',
    '4a2dbc5', '4a44367', '4db560f', '4eba1e6', '4fbca57', '4fbf64c',
    '5a9635c', '5bc7024', '5d15863', '5e79e9b'
)

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$xmlSettings = [System.Xml.XmlReaderSettings]::new()
$xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$xmlSettings.XmlResolver = $null

function Get-NodeText {
    param([System.Xml.XmlNode] $Document, [System.Xml.XmlNamespaceManager] $Namespaces, [string] $Path)
    $node = $Document.SelectSingleNode($Path, $Namespaces)
    if ($null -eq $node) { return '' }
    return $node.InnerText.Trim()
}

function Get-DecimalValue {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [decimal] 0 }
    return [decimal]::Parse($Value, $invariant)
}

function Get-TaxTotal {
    param([xml] $Document, [System.Xml.XmlNamespaceManager] $Namespaces, [string] $SchemeId)
    $total = [decimal] 0
    foreach ($subtotal in $Document.SelectNodes('/*/cac:TaxTotal/cac:TaxSubtotal', $Namespaces)) {
        $schemeNode = $subtotal.SelectSingleNode('cac:TaxCategory/cac:TaxScheme/cbc:ID', $Namespaces)
        if ($null -eq $schemeNode -or $schemeNode.InnerText.Trim() -ne $SchemeId) { continue }
        $amountNode = $subtotal.SelectSingleNode('cbc:TaxAmount', $Namespaces)
        if ($null -ne $amountNode) { $total += Get-DecimalValue $amountNode.InnerText }
    }
    return $total
}

function Get-CellValue {
    param([System.Xml.XmlElement] $Cell, [string[]] $Shared)
    $valueNode = $Cell.SelectSingleNode('*[local-name()="v"]')
    $type = $Cell.GetAttribute('t')
    if ($type -eq 's' -and $null -ne $valueNode) {
        return [string] $Shared[[int] $valueNode.InnerText]
    }
    if ($type -eq 'inlineStr') { return [string] $Cell.InnerText }
    if ($null -ne $valueNode) { return [string] $valueNode.InnerText }
    return ''
}

function Read-Workbook {
    param([string] $Path)
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $shared = @()
        $sharedEntry = $zip.GetEntry('xl/sharedStrings.xml')
        if ($null -ne $sharedEntry) {
            $reader = [System.IO.StreamReader]::new($sharedEntry.Open())
            try { [xml] $sharedXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $shared = @($sharedXml.GetElementsByTagName('si') | ForEach-Object { $_.InnerText })
        }
        $sheetEntry = $zip.GetEntry('xl/worksheets/sheet1.xml')
        if ($null -eq $sheetEntry) { throw 'El Excel no tiene xl/worksheets/sheet1.xml.' }
        $reader = [System.IO.StreamReader]::new($sheetEntry.Open())
        try { [xml] $sheetXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $rows = @($sheetXml.worksheet.sheetData.row)
        $headers = @{}
        foreach ($cell in $rows[0].c) {
            $column = [regex]::Match($cell.r, '^[A-Z]+').Value
            $headers[$column] = Get-CellValue $cell $shared
        }
        $result = @()
        foreach ($row in $rows | Select-Object -Skip 1) {
            $record = [ordered]@{ ExcelRow = [int] $row.r }
            foreach ($header in $headers.Values) { $record[$header] = '' }
            foreach ($cell in $row.c) {
                $column = [regex]::Match($cell.r, '^[A-Z]+').Value
                if (-not $headers.ContainsKey($column)) { continue }
                $record[$headers[$column]] = Get-CellValue $cell $shared
            }
            $result += [pscustomobject] $record
        }
        return @{ Headers = @($headers.Values); Rows = $result }
    } finally {
        $zip.Dispose()
    }
}

function Read-Invoice {
    param([string] $Path)
    $reader = [System.Xml.XmlReader]::Create($Path, $xmlSettings)
    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    try { $document.Load($reader) } finally { $reader.Dispose() }
    if ($document.DocumentElement.LocalName -ne 'Invoice') {
        throw "Solo se compara Invoice: $Path"
    }
    $ns = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $ns.AddNamespace('cbc', 'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2')
    $ns.AddNamespace('cac', 'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2')
    $get = { param([string] $xpath) Get-NodeText $document $ns $xpath }
    $p = '/*/cac:AccountingSupplierParty/cac:Party'
    $t = '/*/cac:LegalMonetaryTotal'
    $invoiceId = & $get '/*/cbc:ID'
    $name = & $get "$p/cac:PartyTaxScheme/cbc:RegistrationName"
    if (-not $name) { $name = & $get "$p/cac:PartyName/cbc:Name" }
    $city = & $get "$p/cac:PhysicalLocation/cac:Address/cbc:CityName"
    if (-not $city) { $city = & $get "$p/cac:PartyTaxScheme/cac:RegistrationAddress/cbc:CityName" }
    $lines = $document.SelectNodes('/*/cac:InvoiceLine', $ns)
    $lineCount = $lines.Count
    $lineRows = @()
    for ($index = 0; $index -lt $lineCount; $index++) {
        $line = $lines[$index]
        $description = Get-NodeText $line $ns './cac:Item/cbc:Description[1]'
        if (-not $description) { $description = Get-NodeText $line $ns './cac:Item/cbc:Name[1]' }
        $quantityNode = $line.SelectSingleNode('./cbc:InvoicedQuantity', $ns)
        $lineRows += [pscustomobject]@{
            Ordinal = $index + 1
            LineId = Get-NodeText $line $ns './cbc:ID'
            Description = $description
            StandardItemCode = Get-NodeText $line $ns './cac:Item/cac:StandardItemIdentification/cbc:ID'
            Quantity = if ($null -ne $quantityNode) { $quantityNode.InnerText.Trim() } else { '' }
            UnitCode = if ($null -ne $quantityNode) { $quantityNode.GetAttribute('unitCode') } else { '' }
            Price = Get-NodeText $line $ns './cac:Price/cbc:PriceAmount'
            LineExtensionAmount = Get-NodeText $line $ns './cbc:LineExtensionAmount'
        }
    }
    $iva = Get-TaxTotal $document $ns '01'
    $inc = Get-TaxTotal $document $ns '04'
    $discount = Get-DecimalValue (& $get '//*[local-name()="MntDctoCop"][1]')
    $charge = Get-DecimalValue (& $get '//*[local-name()="MntRcgoCop"][1]')
    $firstDescription = & $get '/*/cac:InvoiceLine[1]/cac:Item/cbc:Description[1]'
    $values = [ordered]@{
        id_factura = $invoiceId
        cufe = (& $get '/*/cbc:UUID').ToLowerInvariant()
        factura_completa = $invoiceId
        fecha_emision = & $get '/*/cbc:IssueDate'
        nit_proveedor = & $get "$p/cac:PartyTaxScheme/cbc:CompanyID"
        nombre_proveedor = $name
        ciudad_proveedor = $city
        tax_level_proveedor = & $get "$p/cac:PartyTaxScheme/cbc:TaxLevelCode"
        tax_scheme_id = & $get "$p/cac:PartyTaxScheme/cac:TaxScheme/cbc:ID"
        tax_scheme_nombre = & $get "$p/cac:PartyTaxScheme/cac:TaxScheme/cbc:Name"
        codigo_industria_proveedor = & $get "$p/cbc:IndustryClassificationCode"
        cantidad_lineas_xml = & $get '/*/cbc:LineCountNumeric'
        line_extension_amount = & $get "$t/cbc:LineExtensionAmount"
        tax_exclusive_amount = & $get "$t/cbc:TaxExclusiveAmount"
        tax_inclusive_amount = & $get "$t/cbc:TaxInclusiveAmount"
        payable_amount = & $get "$t/cbc:PayableAmount"
        iva_total = $iva
        inc_total = $inc
        descuento_total = $discount
        recargo_total = $charge
        tiene_iva = [int] ($iva -gt 0)
        tiene_inc = [int] ($inc -gt 0)
        flag_descuento = [int] ($discount -gt 0)
        flag_recargo = [int] ($charge -gt 0)
        cantidad_items_total = $lineCount
        descripcion_item_1 = $firstDescription
        item1_proveedor = "$firstDescription - $name"
        n_registros_sugeridos = 2 + [int] ($iva -gt 0) + [int] ($inc -gt 0)
        valor_base_sugerido = & $get "$t/cbc:TaxExclusiveAmount"
        valor_iva_sugerido = $iva
        valor_inc_sugerido = $inc
        valor_cxp_sugerido = & $get "$t/cbc:PayableAmount"
        observaciones = ''
    }
    $canonicalDiscount = & $get "$t/cbc:AllowanceTotalAmount"
    $canonicalCharge = & $get "$t/cbc:ChargeTotalAmount"
    return [pscustomobject]@{
        Path = $Path
        Values = $values
        ActualLines = $lineCount
        LineRows = $lineRows
        UblDiscount = Get-DecimalValue $canonicalDiscount
        UblCharge = Get-DecimalValue $canonicalCharge
    }
}

function Test-Equal {
    param([string] $Field, $Actual, $Expected)
    if ($Field -eq 'fecha_emision') {
        if ([string]::IsNullOrWhiteSpace([string] $Expected)) { return $false }
        $expectedDate = if ([string] $Expected -match '^\d{4}-\d{2}-\d{2}$') {
            [string] $Expected
        } else {
            [DateTime]::FromOADate([double]::Parse([string] $Expected, $invariant)).ToString('yyyy-MM-dd')
        }
        return ([string] $Actual -eq $expectedDate)
    }
    if ($Field -in @(
        'line_extension_amount', 'tax_exclusive_amount', 'tax_inclusive_amount',
        'payable_amount', 'iva_total', 'inc_total', 'descuento_total',
        'recargo_total', 'valor_base_sugerido', 'valor_iva_sugerido',
        'valor_inc_sugerido', 'valor_cxp_sugerido'
    )) {
        return (Get-DecimalValue ([string] $Actual)) -eq (Get-DecimalValue ([string] $Expected))
    }
    if ($Field -in @(
        'cantidad_lineas_xml', 'tiene_iva', 'tiene_inc', 'flag_descuento',
        'flag_recargo', 'cantidad_items_total', 'n_registros_sugeridos'
    )) {
        return [int] $Actual -eq [int] ([string] $Expected).Trim()
    }
    return ([string] $Actual).Trim() -ceq ([string] $Expected).Trim()
}

function Test-EquivalentRepresentation {
    param([string] $Field, $Actual, $Expected)
    $actualText = ([string] $Actual).Trim()
    $expectedText = ([string] $Expected).Trim()
    if ($Field -eq 'tax_scheme_id' -and
        $actualText -match '^\d+$' -and $expectedText -match '^\d+$') {
        return [decimal]::Parse($actualText, $invariant) -eq
            [decimal]::Parse($expectedText, $invariant)
    }
    if ($Field -in @('iva_total', 'valor_iva_sugerido')) {
        return [math]::Abs(
            (Get-DecimalValue $actualText) - (Get-DecimalValue $expectedText)
        ) -le [decimal] 0.00005
    }
    return $false
}

$workbook = Read-Workbook $WorkbookPath
$expectedHeaders = @(
    'id_carga', 'id_factura', 'cufe', 'factura_completa', 'fecha_emision',
    'nit_proveedor', 'nombre_proveedor', 'ciudad_proveedor', 'tax_level_proveedor',
    'tax_scheme_id', 'tax_scheme_nombre', 'codigo_industria_proveedor',
    'cantidad_lineas_xml', 'line_extension_amount', 'tax_exclusive_amount',
    'tax_inclusive_amount', 'payable_amount', 'iva_total', 'inc_total',
    'descuento_total', 'recargo_total', 'tiene_iva', 'tiene_inc',
    'flag_descuento', 'flag_recargo', 'cantidad_items_total',
    'descripcion_item_1', 'item1_proveedor', 'n_registros_sugeridos',
    'valor_base_sugerido', 'valor_iva_sugerido', 'valor_inc_sugerido',
    'valor_cxp_sugerido', 'observaciones'
)
if ($workbook.Headers.Count -ne 34 -or @($expectedHeaders | Where-Object { $_ -notin $workbook.Headers }).Count) {
    throw 'Los 34 encabezados esperados no coinciden con el Excel.'
}
$byCufe = @{}
foreach ($row in $workbook.Rows) {
    if (-not $row.cufe) { continue }
    $key = ([string] $row.cufe).Trim().ToLowerInvariant()
    if (-not $byCufe.ContainsKey($key)) { $byCufe[$key] = @() }
    $byCufe[$key] += $row
}

$fieldCounts = [ordered]@{}
foreach ($field in $expectedHeaders | Where-Object { $_ -ne 'id_carga' }) { $fieldCounts[$field] = 0 }
$details = @()
$files = @()
$projections = @()
$extractedLines = @()
$equivalentCount = 0
$substantiveCount = 0
foreach ($prefix in $prefixes) {
    $matches = @(Get-ChildItem -LiteralPath $XmlDirectory -File -Filter "$prefix*.xml")
    if ($matches.Count -ne 1) { throw "Se esperaba un XML para $prefix; encontrados: $($matches.Count)." }
    $invoice = Read-Invoice $matches[0].FullName
    $values = $invoice.Values
    $key = $values.cufe
    if ($matches[0].BaseName -cne $key) { throw "Nombre de archivo y CUFE distintos: $prefix" }
    if ([int] $values.cantidad_lineas_xml -ne $invoice.ActualLines) { throw "Numero de lineas discordante: $prefix" }
    $rows = @()
    if ($byCufe.ContainsKey($key)) { $rows = @($byCufe[$key]) }
    $projected = [ordered]@{ Xml = $matches[0].Name; id_carga = $null }
    foreach ($field in $fieldCounts.Keys) { $projected[$field] = $values[$field] }
    $projections += [pscustomobject] $projected
    foreach ($line in $invoice.LineRows) {
        $extractedLines += [pscustomobject]@{
            Xml = $matches[0].Name
            Cufe = $key
            Ordinal = $line.Ordinal
            LineId = $line.LineId
            Description = $line.Description
            StandardItemCode = $line.StandardItemCode
            Quantity = $line.Quantity
            UnitCode = $line.UnitCode
            Price = $line.Price
            LineExtensionAmount = $line.LineExtensionAmount
        }
    }
    $mismatches = 0
    foreach ($row in $rows) {
        foreach ($field in @($fieldCounts.Keys)) {
            $actual = $values[$field]
            $expected = $row.$field
            if (-not (Test-Equal $field $actual $expected)) {
                $fieldCounts[$field]++
                $mismatches++
                $equivalent = Test-EquivalentRepresentation $field $actual $expected
                if ($equivalent) { $equivalentCount++ } else { $substantiveCount++ }
                $details += [pscustomobject]@{
                    Xml = $matches[0].Name
                    ExcelRow = $row.ExcelRow
                    Field = $field
                    Extracted = [string] $actual
                    Excel = [string] $expected
                    Classification = if ($equivalent) { 'REPRESENTACION' } else { 'VALOR' }
                }
            }
        }
    }
    $files += [pscustomobject]@{
        Xml = $matches[0].Name
        Cufe = $key
        InvoiceId = $values.id_factura
        LineCount = $invoice.ActualLines
        ExcelRows = $rows.Count
        Mismatches = $mismatches
        UblDiscount = [string] $invoice.UblDiscount
        UblCharge = [string] $invoice.UblCharge
    }
}

$lineSumDifferences = @()
foreach ($projection in $projections) {
    $lineSum = [decimal] 0
    foreach ($line in $extractedLines | Where-Object { $_.Xml -eq $projection.Xml }) {
        $lineSum += Get-DecimalValue $line.LineExtensionAmount
    }
    $headerAmount = Get-DecimalValue $projection.line_extension_amount
    if ($lineSum -ne $headerAmount) {
        $lineSumDifferences += [pscustomobject]@{
            Xml = $projection.Xml
            HeaderLineExtensionAmount = [string] $headerAmount
            SumOfLineExtensionAmounts = [string] $lineSum
            Difference = [string] ($lineSum - $headerAmount)
        }
    }
}

[pscustomobject]@{
    XmlCount = $files.Count
    MatchedXmlCount = @($files | Where-Object { $_.ExcelRows -gt 0 }).Count
    UnmatchedXmlCount = @($files | Where-Object { $_.ExcelRows -eq 0 }).Count
    ComparedExcelRows = @($files | ForEach-Object { $_.ExcelRows } | Measure-Object -Sum).Sum
    ComparedFields = $fieldCounts.Count
    ExtractedLineRows = $extractedLines.Count
    LineSumDifferenceCount = $lineSumDifferences.Count
    NonComparableField = 'id_carga'
    MismatchCount = $details.Count
    EquivalentRepresentationCount = $equivalentCount
    SubstantiveMismatchCount = $substantiveCount
    FieldMismatchCounts = $fieldCounts
    Files = $files
    ProjectionRows = $projections
    LineRows = $extractedLines
    LineSumDifferences = $lineSumDifferences
    Differences = $details
}
