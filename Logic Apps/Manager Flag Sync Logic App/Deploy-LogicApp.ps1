# SYNOPSIS
#   Deploys (creates or updates) the manager-flagging Logic App using the parameterized
#   Bicep template (main.bicep) - or the equivalent ARM JSON template (azuredeploy.json)
#   if you pass -TemplateFile explicitly.
#
# DESCRIPTION
#   Wraps New-AzResourceGroupDeployment so the Logic App can be pushed from PowerShell
#   (locally or from a pipeline) instead of edited by hand in the Azure Portal.
#
#   New-AzResourceGroupDeployment accepts .bicep files directly - Az PowerShell compiles
#   them to ARM JSON on the fly (bundled Bicep CLI, no separate install needed in most
#   recent Az.Resources versions). The same parameter file format works for both
#   main.bicep and azuredeploy.json, since the parameter names are identical.
#
#   Fill in a real parameters file (copy azuredeploy.parameters.example.json to e.g.
#   azuredeploy.parameters.prod.json and replace every placeholder value) and pass its
#   path with -ParameterFile. Do not commit a filled-in parameters file that contains
#   real subscription IDs / resource names to a public or shared repo without checking
#   your organization's policy on that first.
#
# PARAMETERS
#   -ResourceGroupName  The resource group the Logic App should be deployed into.
#   -ParameterFile      Path to a filled-in ARM parameters JSON file (based on
#                       azuredeploy.parameters.example.json).
#   -TemplateFile       Path to the template. Defaults to main.bicep next to this
#                       script. Pass azuredeploy.json explicitly if you'd rather
#                       deploy the plain ARM JSON version.
#   -WhatIf             Runs What-If analysis instead of actually deploying, so you
#                       can review the change first.
#
# EXAMPLES
#   ./Deploy-LogicApp.ps1 -ResourceGroupName "rg-entra-governance" -ParameterFile ./azuredeploy.parameters.prod.json
#   ./Deploy-LogicApp.ps1 -ResourceGroupName "rg-entra-governance" -ParameterFile ./azuredeploy.parameters.prod.json -WhatIf
#   ./Deploy-LogicApp.ps1 -ResourceGroupName "rg-entra-governance" -ParameterFile ./azuredeploy.parameters.prod.json -TemplateFile ./azuredeploy.json

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ParameterFile,

    [Parameter(Mandatory = $false)]
    [string]$TemplateFile = (Join-Path $PSScriptRoot "main.bicep"),

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    throw "The Az.Resources module is required. Install it with: Install-Module Az.Resources -Scope CurrentUser"
}

if (-not (Test-Path $TemplateFile)) {
    throw "Template file not found: $TemplateFile"
}

if (-not (Test-Path $ParameterFile)) {
    throw "Parameter file not found: $ParameterFile. Copy azuredeploy.parameters.example.json and fill in real values first."
}

# Make sure we're logged in and pointed at the right context before deploying.
$context = Get-AzContext
if (-not $context) {
    Write-Host "No active Az session found - launching Connect-AzAccount..."
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}
Write-Host "Deploying as $($context.Account) into subscription $($context.Subscription.Name) ($($context.Subscription.Id))"

$deploymentName = "logicapp-deploy-" + (Get-Date -Format "yyyyMMdd-HHmmss")

if ([string]::IsNullOrWhiteSpace($deploymentName)) {
    throw "Failed to build a deployment name (this should never happen - check that this script's content matches what was provided, some editors/security tools have been known to silently strip lines from downloaded scripts)."
}

$deployParams = @{
    ResourceGroupName     = $ResourceGroupName
    Name                  = $deploymentName
    TemplateFile          = $TemplateFile
    TemplateParameterFile = $ParameterFile
}

if ($WhatIf) {
    Write-Host "Running What-If analysis (no changes will be made)..."
    Get-AzResourceGroupDeploymentWhatIfResult @deployParams
} else {
    Write-Host "Starting deployment '$deploymentName' into resource group '$ResourceGroupName'..."
    try {
        $result = New-AzResourceGroupDeployment @deployParams
    } catch {
        Write-Error "Deployment failed: $($_.Exception.Message)"
        throw
    }
    $result
    if ($result -and $result.Outputs -and $result.Outputs.ContainsKey('logicAppResourceId')) {
        Write-Host "Deployed Logic App resource ID: $($result.Outputs.logicAppResourceId.Value)"
    } else {
        Write-Warning "Deployment call returned, but no logicAppResourceId output was found - check `$result above for details."
    }
}