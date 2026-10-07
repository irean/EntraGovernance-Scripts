function Export-DistributionListWorkbook {
    <#
    .SYNOPSIS
        Writes distribution list rows to Excel with the module's table style and
        a Yes/No dropdown on the Include column.
    .NOTES
        Internal helper, used by Export-SiSDistributionList and
        Sync-SiSAccessPackage.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Rows,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $exportRows = @($Rows | Select-Object -Property * -ExcludeProperty '_ExcelRow')

    $excel = Export-SafeExcelTable -InputObject $exportRows -Path $Path -WorksheetName 'DistributionLists' -TableName 'DistributionLists'

    # Yes/No dropdown on Include, so nobody types "ja", "x" or "Yes "
    $headers = @($exportRows[0].PSObject.Properties.Name)
    $includeIndex = [array]::IndexOf($headers, 'Include') + 1
    if ($includeIndex -gt 0) {
        $n = $includeIndex
        $letter = ''
        while ($n -gt 0) {
            $m = ($n - 1) % 26
            $letter = [char](65 + $m) + $letter
            $n = [Math]::Floor(($n - $m) / 26)
        }
        $ws = $excel.Workbook.Worksheets['DistributionLists']
        Add-ExcelDataValidationRule -Worksheet $ws `
            -Range "$($letter)2:$($letter)$($exportRows.Count + 1)" `
            -ValidationType List -ValueSet @('Yes', 'No') `
            -ShowErrorMessage -ErrorStyle stop `
            -ErrorTitle 'Include' -ErrorBody "Use Yes or No."
    }

    Close-ExcelPackage $excel
}
