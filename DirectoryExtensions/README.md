# Directory Extensions

PowerShell functions for managing custom directory extensions (schema extensions) 
in Microsoft Entra ID. Create, read, update, and remove extension properties on 
user objects — and retrieve their values across the tenant.

---

## Overview

Directory extensions let you store additional metadata on Entra ID user objects 
beyond the default attribute set. This is particularly useful for governance 
scenarios where you need to classify users by HR attributes, lifecycle state, 
or organisational metadata that doesn't map to standard Entra fields.

Related blog post: [agderinthe.cloud](https://agderinthe.cloud/author/sandra/)

---

## Functions

| Function | Description |
|---|---|
| `New-DirectoryExtensionForUser` | Creates a new directory extension property on a registered application |
| `Get-DirectoryExtensions` | Lists all directory extensions for one or all registered applications |
| `Get-DirectoryExtensionValues` | Retrieves extension values for a specific user or all users |
| `Set-DirectoryExtensionValue` | Updates a directory extension value for a specific user |
| `Remove-ApplicationDirectoryExtension` | Safely removes an extension property from an application |
| `Show-AvailableFunctions` | Lists all available functions with their descriptions |

---

## Prerequisites

- PowerShell 7+
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation)

## Required Graph Scopes

| Function | Required Scope |
|---|---|
| `New-DirectoryExtensionForUser` | `Application.ReadWrite.All` |
| `Get-DirectoryExtensions` | `Application.Read.All` |
| `Get-DirectoryExtensionValues` | `User.Read.All` |
| `Set-DirectoryExtensionValue` | `Directory.ReadWrite.All` |
| `Remove-ApplicationDirectoryExtension` | `Application.ReadWrite.All` |

---

## Quick Start

```powershell
# Dot-source the script
. .\DirectoryExtensions.ps1

# List available functions
Show-AvailableFunctions

# Create a new extension on an application
New-DirectoryExtensionForUser `
    -ApplicationObjectID "<app-object-id>" `
    -nameofextension "LifecycleStatus" `
    -dataType "String"

# List all extensions across all registered apps
Get-DirectoryExtensions

# List extensions for a specific app
Get-DirectoryExtensions -AppDisplayName "MyGovernanceApp"

# Get extension values for a specific user
Get-DirectoryExtensionValues -UserUPN "user@domain.com"

# Get all users with a specific extension value set
Get-DirectoryExtensionValues -DirectoryExtensionName "extension_abc123_LifecycleStatus"

# Update an extension value for a user
Set-DirectoryExtensionValue `
    -DirectoryExtensionName "extension_abc123_LifecycleStatus" `
    -UserUPN "user@domain.com" `
    -NewValue "Active"

# Remove an extension property from an application
Remove-ApplicationDirectoryExtension `
    -ApplicationId "<app-object-id>" `
    -ExtensionId "<extension-id>"
```

---

## Notes

- All functions handle Graph connection and scope validation automatically —
  if the required scope is missing, the function reconnects with the correct permissions.
- `Remove-ApplicationDirectoryExtension` includes a confirmation prompt before 
  deletion, as removing an extension property affects all users in the tenant 
  that rely on it.
- Extension names follow the format `extension_{AppClientId}_{ExtensionName}`.
  Use `Get-DirectoryExtensions` to find the full name if needed.

---

## Author

**Sandra Saluti** — Identity & Governance Consultant at Epical
[LinkedIn](https://www.linkedin.com/in/sandra-saluti-6866a686/) ·
[Blog](https://agderinthe.cloud/author/sandra/)