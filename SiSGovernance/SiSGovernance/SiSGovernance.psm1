# ============================================================================
# SiSGovernance - Microsoft Entra ID Governance with Microsoft Graph
# Author: Sandra Saluti
#
# One function per file: Public\ holds the functions you use, Private\ the
# helpers behind them. FunctionsToExport in SiSGovernance.psd1 decides what's
# visible after Import-Module.
# Dependencies (Microsoft.Graph.Authentication, ImportExcel) are declared as
# RequiredModules in the manifest, so nothing is installed at import time.
# ============================================================================

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction Stop)
$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction Stop)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "SiSGovernance: could not load $($file.Name): $_"
    }
}

# No Export-ModuleMember: FunctionsToExport in the manifest decides what's
# public. (It also trips a PSScriptAnalyzer 1.24 bug when analysing the folder.)
