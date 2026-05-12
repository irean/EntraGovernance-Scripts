#Requires -Modules Az.Accounts, Az.Resources, Az.LogicApp

#region Embedded functions

function Test-Module {
    [CmdletBinding()]
    param(
        [String]$Name
    )
    Write-Host "Checking module $Name"
    if (-not (Get-Module $Name)) {
        Write-Host "Module $Name not imported, trying to import"
        try {
            Import-Module $Name -ErrorAction Stop
        }
        catch {
            Write-Host "Module $Name not found, trying to install"
            Install-Module $Name -Scope CurrentUser -AllowClobber -Force -AcceptLicense -SkipPublisherCheck
            Write-Host "Importing module $Name"
            Import-Module $Name -ErrorAction Stop
        }
    }
    else {
        Write-Host "Module $Name is imported"
    }
}

function Set-MIPermissions {
    param (
        [Parameter(Mandatory)]
        [String]$ManagedIdentityId,
        [Parameter(Mandatory)]
        [String]$DisplayName,
        [Parameter()]
        [String[]]$GraphRoles
    )

    if ($GraphRoles) {
        $mgGraph = (Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles").value[0]

        $GraphRoles | ForEach-Object {
            $roleName = $_
            $role = $mgGraph.appRoles | Where-Object { $_.value -eq $roleName }

            if (-not $role) {
                Write-Warning "Graph role '$roleName' not found. Skipping."
                return
            }

            $body = @{
                principalId = $ManagedIdentityId
                resourceId  = $mgGraph.id
                appRoleId   = $role.id
            } | ConvertTo-Json

            try {
                Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ManagedIdentityId/appRoleAssignments" `
                    -Body $body `
                    -ContentType "application/json" | Out-Null
                Write-Host "    Assigned Graph role: $roleName" -ForegroundColor Green
            } catch {
                if ($_ -match "already exists") {
                    Write-Host "    Role '$roleName' already assigned, skipping." -ForegroundColor Yellow
                } else {
                    throw
                }
            }
        }
    }
}

function Deploy-PasswordResetLogicApp {
<#
.SYNOPSIS
    Deploys or updates a Logic App for password reset.

.DESCRIPTION
    Creates or updates a Logic App with tenant-specific parameters,
    enables System-assigned Managed Identity, and assigns required
    Graph API permissions. The Logic App JSON definition is read from
    LogicApp.json in the same folder as this script.

.PARAMETER SubscriptionId
    Azure Subscription ID where the Logic App will be deployed.

.PARAMETER ResourceGroup
    Name of the resource group. Must already exist.

.PARAMETER LogicAppName
    Name of the Logic App to create or update.

.PARAMETER Location
    Azure region, e.g. "swedencentral" or "westeurope".

.PARAMETER MailSender
    Email address used as the sender, e.g. "governance@contoso.com".
    Must have an active mailbox in Exchange Online.

.PARAMETER OnboardingWorkflowIds
    One or more Lifecycle Workflow IDs that trigger the onboarding branch.
    The script builds the or-expression dynamically — any number of IDs supported.

.PARAMETER TenantId
    Azure AD Tenant ID. Required for Service Principal authentication.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for Service Principal authentication.
    Omit for interactive login.

.PARAMETER AppId
    App ID for the Service Principal. Omit for interactive login.

.PARAMETER LogicAppDefinitionPath
    Path to LogicApp.json. Defaults to the same folder as this script.

.EXAMPLE
    # Interactive login
    Deploy-PasswordResetLogicApp `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroup "rg-entra-governance-prod" `
        -LogicAppName "la-Password-Reset" `
        -Location "swedencentral" `
        -MailSender "governance@contoso.com" `
        -OnboardingWorkflowIds @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")

.EXAMPLE
    # Service Principal with certificate, multiple workflow IDs
    Deploy-PasswordResetLogicApp `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroup "rg-entra-governance-prod" `
        -LogicAppName "la-Password-Reset" `
        -Location "swedencentral" `
        -MailSender "governance@contoso.com" `
        -OnboardingWorkflowIds @(
            "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
        ) `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CertificateThumbprint "ABC123..." `
        -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroup,

        [Parameter(Mandatory)]
        [string]$LogicAppName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$MailSender,

        [Parameter(Mandatory)]
        [string[]]$OnboardingWorkflowIds,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$CertificateThumbprint,

        [Parameter()]
        [string]$AppId,

        [Parameter()]
        [string]$LogicAppDefinitionPath = "$PSScriptRoot\LogicApp.json",

        [Parameter()]
        [string]$CustomExtensionDisplayName = "Password Reset Extension",

        [Parameter()]
        [string]$CustomExtensionDescription = "Handles password reset and notification for onboarding and offboarding"
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
    function Write-Ok   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
    function Write-Warn { param([string]$m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
    function Write-Fail { param([string]$m) Write-Host "    [ERR] $m" -ForegroundColor Red; throw $m }

    #region Authentication

    Write-Step "Authenticating against Azure"

    if ($CertificateThumbprint -and $AppId -and $TenantId) {
        Connect-AzAccount `
            -ServicePrincipal `
            -TenantId $TenantId `
            -ApplicationId $AppId `
            -CertificateThumbprint $CertificateThumbprint | Out-Null
        Write-Ok "Authenticated via Service Principal with certificate"
    } else {
        Connect-AzAccount | Out-Null
        Write-Ok "Authenticated interactively"
    }

    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Ok "Subscription set: $SubscriptionId"

    # Ensure TenantId is populated even for interactive login
    if (-not $TenantId) {
        $TenantId = (Get-AzContext).Tenant.Id
        Write-Ok "Tenant ID resolved: $TenantId"
    }

    # Connect Graph using existing Azure context — same session, no second login
    Connect-MgGraph -TenantId $TenantId -NoWelcome | Out-Null
    Write-Ok "Graph connected to tenant: $TenantId"

    #endregion

    #region Read JSON definition

    Write-Step "Reading Logic App definition from $LogicAppDefinitionPath"

    if (-not (Test-Path $LogicAppDefinitionPath)) {
        Write-Fail "File not found: $LogicAppDefinitionPath"
    }

    $definitionRaw = Get-Content $LogicAppDefinitionPath -Raw

    #endregion

    #region Replace tenant-specific values

    Write-Step "Replacing tenant-specific values"

    $definitionRaw = $definitionRaw -replace 'governance@epicalgroup\.com', $MailSender
    Write-Ok "MailSender: $MailSender"

    # Replace placeholder workflow IDs with actual values
    # Template has ONBOARDING_WORKFLOW_ID_1, ONBOARDING_WORKFLOW_ID_2, etc.
    for ($i = 0; $i -lt $OnboardingWorkflowIds.Count; $i++) {
        $placeholder = "ONBOARDING_WORKFLOW_ID_$($i + 1)"
        $definitionRaw = $definitionRaw.Replace($placeholder, $OnboardingWorkflowIds[$i])
    }

    Write-Ok "Onboarding workflow IDs ($($OnboardingWorkflowIds.Count)): $($OnboardingWorkflowIds -join ', ')"

    try {
        $definition = $definitionRaw | ConvertFrom-Json
        Write-Ok "JSON validation OK"
    } catch {
        Write-Fail "Invalid JSON after replacement: $_"
    }

    #endregion

    $principalId = $null

    #region Check if Logic App exists

    Write-Step "Checking if Logic App '$LogicAppName' already exists"

    $existingApp = Get-AzLogicApp `
        -ResourceGroupName $ResourceGroup `
        -Name $LogicAppName `
        -ErrorAction SilentlyContinue

    if ($existingApp) {
        Write-Warn "Logic App already exists — updating"
        $isUpdate = $true
        # Get existing principal ID via ARM REST to avoid propagation wait on update
        $existingArm = Invoke-AzRestMethod `
            -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/${LogicAppName}?api-version=2019-05-01" `
            -Method GET
        $existingPrincipalId = ($existingArm.Content | ConvertFrom-Json).identity.principalId
        if ($existingPrincipalId) {
            $principalId = $existingPrincipalId
            Write-Ok "Reusing existing Managed Identity Principal ID: $principalId"
        }
    } else {
        Write-Ok "Logic App does not exist — creating new"
        $isUpdate = $false
    }

    #endregion

    #region Deploy

    Write-Step "Deploying Logic App"

    # Use ARM REST PUT for both create and update — handles identity in one call
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"

    $deployBody = @{
        location   = $Location
        identity   = @{ type = "SystemAssigned" }
        properties = @{
            state      = "Enabled"
            definition = $definition.definition
        }
    } | ConvertTo-Json -Depth 50 -Compress

    $response = Invoke-AzRestMethod `
        -Path "${resourceId}?api-version=2019-05-01" `
        -Method PUT `
        -Payload $deployBody

    if ($response.StatusCode -notin 200, 201) {
        Write-Fail "Deployment failed. HTTP $($response.StatusCode): $($response.Content)"
    }

    # Check if identity was returned directly in PUT response
    $responseContent = $response.Content | ConvertFrom-Json
    $putPrincipalId = $responseContent.identity.principalId
    if ($putPrincipalId) {
        Write-Ok "Managed Identity provisioned directly from PUT response"
        # On update: keep existing principal ID if PUT returns same or different one
        if (-not $principalId) {
            $principalId = $putPrincipalId
        } else {
            Write-Ok "Keeping pre-fetched principal ID: $principalId"
        }
    } elseif (-not $principalId) {
        Write-Ok "Waiting for Managed Identity to propagate"
        Start-Sleep -Seconds 20
        $armCheck = Invoke-AzRestMethod `
            -Path "${resourceId}?api-version=2019-05-01" `
            -Method GET
        $principalId = ($armCheck.Content | ConvertFrom-Json).identity.principalId
        if (-not $principalId) {
            Write-Fail "Managed Identity not visible after propagation. Try running again."
        }
    }

        $logicApp = Get-AzLogicApp -ResourceGroupName $ResourceGroup -Name $LogicAppName
    $action = if ($isUpdate) { "updated" } else { "created" }
    Write-Ok "Logic App ${action}: $($logicApp.Id)"
    Write-Ok "Managed Identity Principal ID: $principalId"

    #endregion

    #region Permissions

    Write-Step "Assigning Graph API permissions to Managed Identity"
    Write-Ok "Using Principal ID: $principalId"

    if (-not $isUpdate) {
        Write-Host "    New Logic App — waiting 90s for managed identity to propagate in Graph..." -ForegroundColor Yellow
        Start-Sleep -Seconds 90
    }

    Set-MIPermissions `
        -ManagedIdentityId $principalId `
        -DisplayName $LogicAppName `
        -GraphRoles @(
            "Mail.Send",
            "UserAuthenticationMethod.ReadWrite.All",
            "AuditLog.Read.All",
            "User.ReadWrite.All",
            "User.RevokeSessions.All",
            "User-PasswordProfile.ReadWrite.All"
        )

    Write-Ok "Permissions assigned"

    #region Entra ID Role Assignment

    Write-Step "Assigning User Administrator role to Managed Identity"

    $userAdminRole = Get-MgDirectoryRole | Where-Object { $_.DisplayName -eq "User Administrator" }
    if (-not $userAdminRole) {
        $roleTemplate = Get-MgDirectoryRoleTemplate | Where-Object { $_.DisplayName -eq "User Administrator" }
        $userAdminRole = New-MgDirectoryRole -RoleTemplateId $roleTemplate.Id
    }

    $existingMember = Get-MgDirectoryRoleMember -DirectoryRoleId $userAdminRole.Id | 
        Where-Object { $_.Id -eq $principalId }

    if (-not $existingMember) {
        try {
            New-MgDirectoryRoleMemberByRef -DirectoryRoleId $userAdminRole.Id -BodyParameter @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$principalId"
            }
            Write-Ok "User Administrator role assigned to managed identity"
        } catch {
            if ($_ -match "already exist") {
                Write-Ok "User Administrator role already assigned"
            } else {
                throw
            }
        }
    } else {
        Write-Ok "User Administrator role already assigned"
    }

    #endregion

    #region Authorization policy

    Write-Step "Configuring authorization policy for Lifecycle Workflows"

    # Get the managed identity Application ID (different from Principal/Object ID)
    $mgIdentitySp = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId"
    $managedIdentityAppId = $mgIdentitySp.appId
    Write-Ok "Managed Identity App ID (for auth policy): $managedIdentityAppId"
    Write-Ok "Managed Identity Object ID (Principal ID):  $principalId"
    Write-Ok "If these match, something is wrong — App ID and Object ID should be different values"  

    # Lifecycle Workflows service app ID — resolve dynamically as display name varies by tenant
    $lcwSp = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=displayName eq 'Microsoft Entra Lifecycle Workflows' or displayName eq 'AAD Lifecycle Management'&`$select=appId,displayName"
    $lifecycleWorkflowsAppId = ($lcwSp.value | Select-Object -First 1).appId
    if (-not $lifecycleWorkflowsAppId) {
        throw "Could not find Lifecycle Workflows service principal in tenant. Cannot set authorization policy."
    }
    Write-Ok "Lifecycle Workflows App ID: $lifecycleWorkflowsAppId"

    $logicAppResourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"

    # p claim = ARM resource path of the Logic App (not the trigger URL path)
    $pClaim = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"

    # Build POP authorization policy — will be merged into full Logic App PUT
    $authPolicy = @{
        properties = @{
            accessControl = @{
                triggers = @{
                    openAuthenticationPolicies = @{
                        policies = @{
                            AzureADLifecycleWorkflowsAuthPOPAuthPolicy = @{
                                type   = "AADPOP"
                                claims = @(
                                    @{ name = "iss"; value = "https://sts.windows.net/$TenantId/" },
                                    @{ name = "aud"; value = "https://management.azure.com" },
                                    @{ name = "appid"; value = $lifecycleWorkflowsAppId },
                                    @{ name = "m"; value = "POST" },
                                    @{ name = "u"; value = "management.azure.com" },
                                    @{ name = "p"; value = $pClaim }
                                )
                            }
                        }
                    }
                    sasAuthenticationPolicy = @{
                        state = "Disabled"
                    }
                }
            }
        }
    } | ConvertTo-Json -Depth 10

    # GET the current full Logic App definition and merge auth policy into it
    $currentApp = (Invoke-AzRestMethod `
        -Path "${logicAppResourcePath}?api-version=2019-05-01" `
        -Method GET).Content | ConvertFrom-Json

    $newAccessControl = ($authPolicy | ConvertFrom-Json).properties.accessControl

    # Add accessControl if it doesn't exist yet
    if (-not $currentApp.properties.PSObject.Properties['accessControl']) {
        $currentApp.properties | Add-Member -MemberType NoteProperty -Name accessControl -Value $newAccessControl
    } else {
        $currentApp.properties.accessControl = $newAccessControl
    }

    $fullPutBody = $currentApp | ConvertTo-Json -Depth 50 -Compress

    $authResponse = Invoke-AzRestMethod `
        -Path "${logicAppResourcePath}?api-version=2019-05-01" `
        -Method PUT `
        -Payload $fullPutBody

    if ($authResponse.StatusCode -notin 200, 201) {
        Write-Warn "Authorization policy may not have been set correctly. HTTP $($authResponse.StatusCode)"
        Write-Warn "Error: $($authResponse.Content)"
        Write-Warn "You may need to set it manually in the Azure Portal under Logic App -> Authorization"
    } else {
        Write-Ok "Authorization policy configured and SAS disabled — Logic App is now compatible with Lifecycle Workflows"
    }

    #endregion

    #region Register custom task extension

    Write-Step "Registering Logic App as custom task extension in Lifecycle Workflows"

    $customExtensionBody = @{
        displayName          = $CustomExtensionDisplayName
        description          = $CustomExtensionDescription
        endpointConfiguration = @{
            "@odata.type"        = "#microsoft.graph.logicAppTriggerEndpointConfiguration"
            subscriptionId       = $SubscriptionId
            resourceGroupName    = $ResourceGroup
            logicAppWorkflowName = $LogicAppName
        }
        authenticationConfiguration = @{
            "@odata.type" = "#microsoft.graph.azureAdPopTokenAuthentication"
        }
        clientConfiguration = @{
            "@odata.type"         = "#microsoft.graph.customExtensionClientConfiguration"
            maximumRetries        = 1
            timeoutInMilliseconds = 1000
        }
        callbackConfiguration = @{
            "@odata.type"   = "#microsoft.graph.identityGovernance.customTaskExtensionCallbackConfiguration"
            timeoutDuration = "PT1H"
        }
    } | ConvertTo-Json -Depth 10

    # Check if extension with same name already exists
    $existingExtensions = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/customTaskExtensions?`$filter=displayName eq '$CustomExtensionDisplayName'"
    $existingExtension = $existingExtensions.value | Select-Object -First 1

    if ($existingExtension) {
        Write-Warn "Custom task extension '$CustomExtensionDisplayName' already exists — updating"
        $extensionResponse = Invoke-MgGraphRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/customTaskExtensions/$($existingExtension.id)" `
            -Body $customExtensionBody `
            -ContentType "application/json"
        $customExtensionId = $existingExtension.id
        Write-Ok "Custom task extension updated: $customExtensionId"
    } else {
        $extensionResponse = Invoke-MgGraphRequest `
            -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/lifecycleWorkflows/customTaskExtensions" `
            -Body $customExtensionBody `
            -ContentType "application/json"

        if ($extensionResponse.id) {
            Write-Ok "Custom task extension registered: $($extensionResponse.id)"
            $customExtensionId = $extensionResponse.id
        } else {
            Write-Warn "Could not register custom task extension automatically."
            Write-Warn "Register it manually in Entra ID -> Identity Governance -> Lifecycle Workflows -> Custom extensions"
            $customExtensionId = $null
        }
    }

    #endregion

    #region Summary

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Deployment complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Logic App:        $LogicAppName"
    Write-Host "  Resource Group:   $ResourceGroup"
    Write-Host "  Location:         $Location"
    Write-Host "  Mail sender:      $MailSender"
    Write-Host "  Workflow IDs ($($OnboardingWorkflowIds.Count)):"
    $OnboardingWorkflowIds | ForEach-Object { Write-Host "    - $_" }
    Write-Host "  Principal ID:     $principalId"
    if ($customExtensionId) {
        Write-Host "  Extension ID:     $customExtensionId"
    }
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    if ($customExtensionId) {
        Write-Host "  - Go to Entra ID -> Identity Governance -> Lifecycle Workflows" -ForegroundColor Yellow
        Write-Host "  - Add a 'Run a custom task extension' task to your workflow" -ForegroundColor Yellow
        Write-Host "  - Select the extension: $CustomExtensionDisplayName" -ForegroundColor Yellow
        Write-Host "  - Set the task behavior to: Launch and continue" -ForegroundColor Yellow
    } else {
        Write-Host "  - Register the Logic App manually as a custom extension in Lifecycle Workflows" -ForegroundColor Yellow
    }
    Write-Host "========================================" -ForegroundColor Cyan

    #endregion
}

#endregion