function Confirm-GraphConnection {
    <#
    .SYNOPSIS
        Checks that there is a Microsoft Graph connection with the scopes the
        calling function needs, and returns the context - or writes an error
        saying exactly which Connect-MgGraph command to run, and returns $null.
    .DESCRIPTION
        The module never calls Connect-MgGraph itself, so it can run anywhere the
        caller controls the sign-in: interactively, with a certificate, or with a
        managed identity in an Azure Function or Automation runbook.

        A higher-privileged permission is accepted in place of the one asked for
        (e.g. Group.Read.All for GroupMember.Read.All).

        Delegated (signed-in user): a missing scope stops the run.
        App-only: a missing scope is a warning, because an app can be given an
        Entitlement Management role instead of the permission.
    .PARAMETER Scopes
        The scopes the calling function needs. Default: User.Read.All,
        EntitlementManagement.ReadWrite.All (Add-/Remove-SiSAccessPackageAssignment).
    .NOTES
        Internal helper.
    #>

    [CmdletBinding()]
    param(
        # Least privilege: each function checks only for what it uses. The
        # default is what Add-/Remove-SiSAccessPackageAssignment needs.
        [Parameter(Mandatory = $false)]
        [string[]]$Scopes = @(
            "User.Read.All",
            "EntitlementManagement.ReadWrite.All"
        )
    )

    $requiredScopes = @($Scopes | Where-Object { $_ } | Select-Object -Unique)
    $connectHint = "Connect-MgGraph -Scopes $($requiredScopes -join ', ')"

    # The module never signs in by itself. The caller decides how: interactive,
    # certificate, managed identity in an Azure Function...
    $context = Get-MgContext
    if (-not $context) {
        Write-Error -Message "Not connected to Microsoft Graph. Connect first, e.g.: $connectHint" -Category ConnectionError
        return $null
    }

    # A higher-privileged permission covers a scope too, so someone with
    # Group.Read.All isn't stopped for lacking GroupMember.Read.All
    $coveredBy = @{
        'User.Read.All'                  = @('User.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
        'GroupMember.Read.All'           = @('GroupMember.ReadWrite.All', 'Group.Read.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
        'EntitlementManagement.Read.All' = @('EntitlementManagement.ReadWrite.All')
    }
    $granted = @($context.Scopes)
    $missingScopes = @($requiredScopes | Where-Object {
            $accepted = @($_) + @($coveredBy[$_] | Where-Object { $_ })
            -not @($accepted | Where-Object { $granted -contains $_ })
        })

    $who = if ($context.Account) { $context.Account } else { "app $($context.ClientId)" }

    if ($missingScopes.Count -gt 0) {
        if ("$($context.AuthType)" -eq 'AppOnly') {
            # An app can hold an Entitlement Management role (e.g. Access package
            # manager) instead of the permission - that never shows in the token
            Write-Warning "The app's token doesn't include: $($missingScopes -join ', '). Continuing - the app may have an Entitlement Management role instead. Graph rejects the calls if it has neither."
        }
        else {
            Write-Error -Message "Connected as $who, but the token is missing: $($missingScopes -join ', '). Reconnect with: $connectHint" -Category PermissionDenied
            return $null
        }
    }

    Write-Host "Using Microsoft Graph connection: $who" -ForegroundColor Green
    return $context
}
