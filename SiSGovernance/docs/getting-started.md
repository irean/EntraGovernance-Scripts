# Getting started

## Install

```powershell
Install-Module SiSGovernance -Scope CurrentUser -AllowPrerelease
```

This also installs the two modules SiSGovernance depends on: `Microsoft.Graph.Authentication` and `ImportExcel`. They're declared as `RequiredModules` in the module manifest, so `Install-Module` installs them and `Import-Module SiSGovernance` loads them. SiSGovernance itself never installs or imports anything while it runs.

| Requirement | |
|---|---|
| PowerShell | 5.1 or 7+ |
| Operating system | Windows for the folder picker. Everything else runs anywhere PowerShell does — give the folder with `-OutputPath`, or skip the assignment report with `-SkipReport`. |

## Connect

SiSGovernance never signs in by itself — you connect to Microsoft Graph first, the way that suits where it runs. Every function then checks that the connection has the scopes it needs, and stops with the exact `Connect-MgGraph` command to run if it doesn't.

Interactively, connect once with everything the module uses:

```powershell
Connect-MgGraph -Scopes User.Read.All, GroupMember.Read.All, EntitlementManagement.ReadWrite.All
```

Or only what you're about to run — see the scopes per function in [Security](security.md).

### In an Azure Function or Automation runbook

Because the module doesn't open a sign-in window, it runs unattended with any non-interactive sign-in:

```powershell
# Managed identity
Connect-MgGraph -Identity

# App registration with a certificate
Connect-MgGraph -ClientId $appId -TenantId $tenantId -CertificateThumbprint $thumbprint

# Then, with no dialogs and no prompts
Sync-SiSAccessPackage -ExcelPath $file -CatalogName "Distribution Lists" -OutputPath $folder -Confirm:$false
$upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId -SkipReport -Confirm:$false
```

See [Running without any input](how-it-works.md#running-without-any-input) for every function.

The identity needs the application permissions for what it runs (see [Security](security.md)). For Entitlement Management, it can also be given a role such as *Access package manager* on the catalog instead of `EntitlementManagement.ReadWrite.All`. That role doesn't show in the token, so for app-only connections a missing Entitlement Management permission gives a warning instead of stopping the run.

## Permissions

Two things decide what a run can do: the **scopes** of your Graph connection, and the **role** of the account you sign in with. The role is what really limits it — see [Security](security.md).

| You want to | Least privileged role (on the catalog) |
|---|---|
| Create packages, add/remove resources | Access package manager |
| Add/remove assignments | Access package assignment manager |
| Only read | Catalog reader |

Activate the role with PIM for the run, rather than having it permanently.

## Your first access package

```powershell
# 1. Create it - preview first, then for real
New-SiSAccessPackage -DisplayName "App - Employee - Sales Portal" -Description "Access to the Sales Portal" `
    -CatalogName "Identity - Employee" -WhatIf

New-SiSAccessPackage -DisplayName "App - Employee - Sales Portal" -Description "Access to the Sales Portal" `
    -CatalogName "Identity - Employee" |
    Add-SiSAccessPackageResource -GroupId $salesPortalGroupId
```

`New-SiSAccessPackage` creates an empty package without policies. The output pipes straight into `Add-SiSAccessPackageResource`.

2. **Add an assignment policy** in the Entra admin center (*Identity Governance → Access packages → your package → Policies*). SiSGovernance doesn't create policies yet.

3. **Assign users:**

```powershell
'anna@contoso.com', 'erik@contoso.com' |
    Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId
```

## What to expect when you run something

Every function that changes something:

1. reads everything first and changes nothing,
2. shows a preview of what will happen,
3. asks for confirmation (`[Y] Yes / [N] No`) — once, also when many objects are piped in. `-Confirm:$false` skips it,
4. makes the changes, and reports a status per object.

`-WhatIf` stops after step 2. More in [How it works](how-it-works.md).
