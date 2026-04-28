function test-module {
    [CmdletBinding()]
    param(
        [String]$Name
  
    )
    Write-Host "Checking module $name"
    if (-not (Get-Module $Name)) {
        Write-Host "Module $Name not imported, trying to import"
        try {
            if ($Name -eq 'Microsoft.Graph') {
                Write-Host "Microsoft.Graph module import takes a while"
                Import-Module $Name  -ErrorAction Stop
            }
            elseif ($Name -eq 'Az') {
                Write-Host "Module Az is being imported. This might take a while"
            }
            else {
                Import-Module $Name  -ErrorAction Stop
            }
        
        }
        catch {
            Write-Host "Module $Name not found, trying to install"
            Install-Module $Name -Scope CurrentUser -AllowClobber -Force -AcceptLicense -SkipPublisherCheck
            Write-Host "Importing module  $Name "
            Import-Module $Name  -ErrorAction stop 
        }
    } 
    else {
        Write-Host "Module $Name is imported"
    }   
}

function Set-MIPermissions {
    param (
        [Parameter()]
        [String]$ManagedIdentityId,
        [Parameter()]
        [String]$AppId,
        [Parameter()]
        [String]$DisplayName,
        [Parameter()]
        [String[]]$GraphRoles,
        [Parameter()]
        [String[]]$ExchangeRoles
    )

    test-module -name Microsoft.Graph.Authentication
    test-module -name Microsoft.Graph.Applications
    test-module -name ExchangeOnlineManagement

    # ── Microsoft Graph permissions ──────────────────────────────────────────
    if ($GraphRoles) {

        Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All, RoleManagement.ReadWrite.Directory

        $mgGraph = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

        $GraphRoles | ForEach-Object {
            $roleName = $_
            $role = $mgGraph.AppRoles | Where-Object { $_.Value -eq $roleName }

            if (-not $role) {
                Write-Warning "Graph role '$roleName' not found. Skipping."
                return
            }

            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $ManagedIdentityId `
                -PrincipalId $ManagedIdentityId `
                -ResourceId $mgGraph.Id `
                -AppRoleId $role.Id

            Write-Host "Assigned Graph role: $roleName" -ForegroundColor Green
        }
    }

    # ── Exchange Online API permissions ──────────────────────────────────────
    if ($ExchangeRoles) {

        Connect-MgGraph -Scopes Application.Read.All, AppRoleAssignment.ReadWrite.All, RoleManagement.ReadWrite.Directory

        $exchangeSP = Get-MgServicePrincipal -Filter "AppId eq '00000002-0000-0ff1-ce00-000000000000'"

        if (-not $exchangeSP) {
            Write-Error "Exchange Online service principal not found in tenant."
            return
        }

        $ExchangeRoles | ForEach-Object {
            $roleName = $_
            $role = $exchangeSP.AppRoles | Where-Object { $_.Value -eq $roleName }

            if (-not $role) {
                Write-Warning "Exchange role '$roleName' not found. Skipping."
                return
            }

            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $ManagedIdentityId `
                -PrincipalId $ManagedIdentityId `
                -ResourceId $exchangeSP.Id `
                -AppRoleId $role.Id

            Write-Host "Assigned Exchange API role: $roleName" -ForegroundColor Green
        }
    }

    # ── Exchange RBAC roles ───────────────────────────────────────────────────
    if ($ExchangeRoles -or $GraphRoles) {

        Connect-ExchangeOnline

        # Ensure the managed identity is registered as a service principal in Exchange
        $exoSP = Get-ServicePrincipal | Where-Object { $_.AppId -eq $AppId }

        if (-not $exoSP) {
            Write-Host "Registering managed identity in Exchange Online..." -ForegroundColor Yellow

            if (-not $AppId -or -not $DisplayName) {
                Write-Error "AppId and DisplayName are required to register the managed identity in Exchange Online."
                return
            }

            $exoSP = New-ServicePrincipal `
                -AppId $AppId `
                -ObjectId $ManagedIdentityId `
                -DisplayName $DisplayName
        }

        Write-Host "Exchange service principal: $($exoSP.DisplayName) / $($exoSP.ObjectId)" -ForegroundColor Cyan
    }
}