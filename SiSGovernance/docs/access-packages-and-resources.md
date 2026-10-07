# Access packages and resources

An access package is a **stable identity**. The resources inside it are **swappable content**. That's why creating a package and managing what it grants are separate functions: the package, its name, its policies and its approvals stay put while the resources change.

## Create an access package

```powershell
New-SiSAccessPackage -DisplayName "License - Baseline 5" -Description "Baseline license for employees" `
    -CatalogName "Identity - Employee"
```

| Parameter | |
|---|---|
| `-DisplayName`, `-Description` | Required |
| `-CatalogName` or `-CatalogId` | The catalog. A name that matches more than one catalog stops the run — use the id then. |
| `-IsHidden` | Hide the package in My Access; users need the direct link |
| `-WhatIf` | Check and show, change nothing |
| `-Confirm:$false` | Create without asking |

- Stops if a package with the same name already exists in the catalog (Entra itself allows duplicates).
- Returns `Id`, `DisplayName`, `CatalogId`, `CatalogName`, `IsHidden` — `Id` binds to `-AccessPackageId` of the resource functions through the pipeline.
- No resources and no policy are created.

## Resource types

Every resource type works the same way in Entitlement Management — *resource in the catalog → its roles → root scope → linked to the package*. Only the identifiers differ:

| Parameter set | Resource | Role |
|---|---|---|
| `-GroupId` | Entra security group or Microsoft 365 group | `-Role Member` (default) or `Owner` |
| `-ApplicationId` | ObjectId of the application's **service principal** (Enterprise application) — not the app registration's appId | `-RoleName`: one of the app's roles |
| `-SiteUrl` | SharePoint Online site | `-RoleName`: one of the site's groups, e.g. `Members`, `Visitors`, `Owners` |

### Which roles are there?

Groups always have `Member` and `Owner`. For applications and SharePoint sites, list them:

```powershell
Get-SiSAccessPackageResourceRole -ApplicationId $appSpId -CatalogName "Identity - Employee"
Get-SiSAccessPackageResourceRole -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -CatalogName "Identity - Employee"
```

Roles are only visible once the resource is in the catalog. If it isn't, the function stops with an error that says so — add `-AddToCatalog` to add it and list the roles in one go (`-WhatIf` shows it without adding).

## Add a resource

```powershell
# Group (Member role)
Add-SiSAccessPackageResource -AccessPackageId $apId -GroupId $groupId

# Application role
Add-SiSAccessPackageResource -AccessPackageId $apId -ApplicationId $appSpId -RoleName "User"

# SharePoint site
Add-SiSAccessPackageResource -AccessPackageId $apId -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -RoleName "Members"

# The same group on several packages - one preview, one confirmation
$apId1, $apId2 | Add-SiSAccessPackageResource -GroupId $groupId
```

- If the resource isn't in the package's catalog yet, it's added to the catalog first (once per catalog, even for many packages).
- **Everyone already assigned to the package gets the role.** The preview says so.
- A role name that doesn't exist fails with the list of roles that do. For a resource that wasn't in the catalog yet, the role can only be checked after the resource is added — so a misspelled role name still leaves the resource in the catalog.

## Remove a resource

```powershell
Remove-SiSAccessPackageResource -AccessPackageId $apId -GroupId $groupId
```

- **Everyone assigned to the package loses the role.**
- The resource stays in the catalog — other packages may use it.

## Swap a resource

This is why adding and removing are separate functions. Example: a baseline license package moves from E5 to E7.

```powershell
Add-SiSAccessPackageResource    -AccessPackageId $apId -GroupId $licE7GroupId
Remove-SiSAccessPackageResource -AccessPackageId $apId -GroupId $licE5GroupId
```

Same package, same name, same approvals — everyone assigned is moved to the new group without being re-approved. Add first, then remove, so nobody is without access in between.

## Results

One object per package:

| Property | |
|---|---|
| `AccessPackageId`, `AccessPackageName` | |
| `ResourceType`, `Resource`, `Role` | |
| `Status` | `Added`, `AlreadyAdded`, `Removed`, `NotOnPackage`, `Preview - <action>`, `Cancelled`, `Failed` |
| `Error` | Why, when `Failed` |

`AlreadyAdded` and `NotOnPackage` mean nothing needed to change — re-running is safe.
