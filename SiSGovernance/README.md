# SiSGovernance

[![Tests](https://github.com/irean/EntraGovernance-Scripts/actions/workflows/sisgovernance.yml/badge.svg)](https://github.com/irean/EntraGovernance-Scripts/actions/workflows/sisgovernance.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/SiSGovernance?include_prereleases)](https://www.powershellgallery.com/packages/SiSGovernance)
[![Downloads](https://img.shields.io/powershellgallery/dt/SiSGovernance)](https://www.powershellgallery.com/packages/SiSGovernance)

PowerShell module for **Microsoft Entra ID Governance** with Microsoft Graph — access packages, their resources and assignments, in bulk and safely.

- **Access packages and resources** — create packages; add, remove and swap groups, applications and SharePoint sites without touching the package or its approvals.
- **Assignments in bulk** — from UPNs, the pipeline, an Excel file or a Graph filter.
- **Distribution lists → access packages** — export, review in Excel, create the packages and the Logic App mapping.
- **Built for real tenants** — batched Graph calls with retry and pacing, `-WhatIf` and one confirmation before anything changes, and every run safe to repeat.
- **Runs anywhere** — you control the Graph sign-in, so it works interactively and unattended in an Azure Function or Automation runbook.

> **Status:** `1.0.0-preview1` — first public preview.

## Install

```powershell
Install-Module SiSGovernance -Scope CurrentUser -AllowPrerelease
```

PowerShell 5.1 or 7+. `Microsoft.Graph.Authentication` and `ImportExcel` are installed automatically.

## Quick start

```powershell
# Connect your way - the module never signs in by itself
Connect-MgGraph -Scopes User.Read.All, GroupMember.Read.All, EntitlementManagement.ReadWrite.All

# A new access package with a group, in one pipeline
New-SiSAccessPackage -DisplayName "License - Baseline 5" -Description "Baseline license" -CatalogName "Identity - Employee" |
    Add-SiSAccessPackageResource -GroupId $groupId

# Assign users from anywhere
$users | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId

# Preview first - nothing changes
Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId `
    -Filter "userType eq 'Member' and department eq 'Sales'" -WhatIf
```

## Functions

| Function | |
|---|---|
| `New-SiSAccessPackage` | Create an empty access package |
| `Add-SiSAccessPackageResource` / `Remove-SiSAccessPackageResource` | Add or remove a group, application or SharePoint role |
| `Get-SiSAccessPackageResourceRole` | List the roles a resource offers |
| `Add-SiSAccessPackageAssignment` / `Remove-SiSAccessPackageAssignment` | Assign or remove users in bulk |
| `Export-SiSDistributionList` | Export distribution lists to Excel |
| `Sync-SiSAccessPackage` | Create, link or update access packages from that file |
| `Get-SiSGraphUser` | Users matching a Graph filter |

Full help for each: `Get-Help <function> -Full`, and an overview: `Get-Help about_SiSGovernance`.

## Documentation

- [Getting started](docs/getting-started.md) — install, permissions, your first access package
- [Access packages and resources](docs/access-packages-and-resources.md)
- [Assignments](docs/assignments.md)
- [Distribution lists](docs/distribution-lists.md) — step by step
- [How it works](docs/how-it-works.md) — `-WhatIf` and `-Confirm`, errors, results, batching, retry, pacing, unattended runs
- [Security](docs/security.md) — scopes, least privileged roles, app consent
- [Development](docs/development.md) — tests, script analysis, GitHub Actions, releases

## Acknowledgements

- [ImportExcel](https://github.com/dfinke/ImportExcel) by Doug Finke — every Excel file in and out of this module goes through it, without Excel having to be installed. Thank you.
- [Microsoft Graph PowerShell SDK](https://github.com/microsoftgraph/msgraph-sdk-powershell) — the sign-in and the connection to Graph.

## Author

Sandra Saluti — [github.com/irean](https://github.com/irean)

## License

[MIT](LICENSE)
