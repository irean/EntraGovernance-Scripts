function Select-FolderPath {
    <#
    .SYNOPSIS
        Opens a folder picker dialog for selecting an export folder.
    .EXAMPLE
        $folderPath = Select-FolderPath
    #>

    [CmdletBinding()]
    param()

    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Please select a folder where the report will be saved." -ForegroundColor Cyan
    Write-Host "The folder selection window may appear behind other open windows." -ForegroundColor Yellow
    Write-Host "If you don't see it, try minimizing other windows." -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray

    Add-Type -AssemblyName System.Windows.Forms

    $FileBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
        Description         = "Select a folder for the report export"
        RootFolder          = [Environment+SpecialFolder]::Desktop
        ShowNewFolderButton = $true
    }

    $form = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $result = $FileBrowser.ShowDialog($form)

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $folder = $FileBrowser.SelectedPath
        Write-Host "Export folder selected: $folder" -ForegroundColor Green
        return $folder
    }
    else {
        return $null
    }
}
