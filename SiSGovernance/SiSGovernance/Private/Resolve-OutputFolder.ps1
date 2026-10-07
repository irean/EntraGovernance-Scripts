function Resolve-OutputFolder {
    <#
    .SYNOPSIS
        Returns the folder to save results in: -OutputPath if given (and it
        exists), otherwise the folder picked in Select-FolderPath. $null means
        stop - the calling function hasn't done anything yet at that point.
    .NOTES
        Internal helper. Called at the START of a run, so a long run never stops
        halfway to ask where to save.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    if ($OutputPath) {
        if (-not (Test-Path -Path $OutputPath -PathType Container)) {
            Write-Error -Message "Output folder not found: $OutputPath" -Category ObjectNotFound -TargetObject $OutputPath
            return $null
        }
        $folder = (Resolve-Path -Path $OutputPath).Path
        Write-Host "Results will be saved to: $folder" -ForegroundColor Green
        return $folder
    }

    $folder = Select-FolderPath
    if (-not $folder) {
        Write-Warning "No output folder selected. Nothing was done."
    }
    return $folder
}
