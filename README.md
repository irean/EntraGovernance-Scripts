# EntraGovernance-Scripts

Practical PowerShell scripts for Entra ID identity governance — directory extensions, 
guest access lifecycle, dynamic license groups, and managed identity permissions.

Built from real-world consulting work. These scripts solve problems that documentation 
glosses over.

Related blog posts at [agderinthe.cloud](https://agderinthe.cloud/author/sandra/)

---

## Contents

| Script / Folder | What it does |
|---|---|
| `setmanagedidentitypermissions.ps1` | Grants Microsoft Graph API permissions to a managed identity — no client secrets required |
| `newsecuritygroupdynamicuser.ps1` | Creates dynamic user security groups targeting specific license service plans |
| `DirectoryExtensions/` | Scripts for working with Entra ID directory extensions as governance metadata |
| `Guest Users/` | Guest account lifecycle and access management tooling |
| `HelperFunctions/` | Reusable helper functions including module validation and PSCustomObject conversion |

---

## Prerequisites

- PowerShell 7+
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation)
- Appropriate Entra ID permissions per script (documented in each script header)

---

## Quick Start

### Set permissions on a Managed Identity

```powershell
Set-MIPermissions -ManagedIdentityId "" `
                  -Roles 'User.Read.All', 'Directory.Read.All'
```

**Required permissions:** `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, 
`RoleManagement.ReadWrite.Directory`

### Create a dynamic license group

```powershell
New-MgSecurityGroupDynamicUser -licname "M365_E3" `
                                -ServicePlanID "" `
                                -orgnames "contoso"
```

---

## Design Philosophy

Good identity governance is less about clever PowerShell and more about asking 
the right questions — of your HR system, your business stakeholders, and your 
own assumptions. These scripts are designed to support well-designed processes, 
not replace them.

A few principles baked in:
- **Use Object ID, not UPN** — display names and email addresses change. Object ID doesn't.
- **Use Managed Identities** — client secrets are passwords. Stop using them.
- **Directory extensions over Exchange attributes** — for governance metadata that 
  needs to work across systems.

---

## Contributing

Found a bug or have an improvement? Issues and PRs are welcome.

---

## Author

**Sandra Saluti** — Identity & Governance Consultant at Epical  
[LinkedIn](https://www.linkedin.com/in/sandra-saluti-6866a686/) · 
[Blog](https://agderinthe.cloud/author/sandra/)