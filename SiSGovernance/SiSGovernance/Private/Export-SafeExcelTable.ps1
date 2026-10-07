function Export-SafeExcelTable {
    <#
    .SYNOPSIS
        Writes objects to an Excel table, with text that comes from Entra kept
        as text - never turned into a formula or a link.
    .DESCRIPTION
        Export-Excel turns text that starts with '=' into a formula, and text
        that looks like a URL into a clickable link. Names and addresses in
        these files come from Entra, where anyone who can rename a group or a
        user decides the text. So no link conversion, and every value that
        starts with '=' is written back as plain text (with Excel's quote
        prefix, so it shows exactly as it is and reads back unchanged).
    .OUTPUTS
        The open ExcelPackage - the caller closes it with Close-ExcelPackage.
    .NOTES
        Internal helper. Protects against formula injection (CWE-1236).
    #>

    [OutputType('OfficeOpenXml.ExcelPackage')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$WorksheetName,

        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $excel = $InputObject | Export-Excel -Path $Path `
        -WorksheetName $WorksheetName -TableName $TableName `
        -TableStyle Medium2 -AutoSize -FreezeTopRow -BoldTopRow `
        -NoHyperLinkConversion '*' -PassThru

    $ws = $excel.Workbook.Worksheets[$WorksheetName]
    $headers = @($InputObject[0].PSObject.Properties.Name)
    for ($r = 0; $r -lt $InputObject.Count; $r++) {
        for ($c = 0; $c -lt $headers.Count; $c++) {
            $value = $InputObject[$r].($headers[$c])
            if ($value -is [string] -and $value.StartsWith('=')) {
                $cell = $ws.Cells[($r + 2), ($c + 1)]
                $cell.Formula = $null
                $cell.Value = $value
                $cell.Style.QuotePrefix = $true
            }
        }
    }
    $excel
}
