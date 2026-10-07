# Security

## Scopes per function

The module never signs in by itself — you connect with `Connect-MgGraph` (see [Getting started](getting-started.md#connect)). Each function checks that the connection has what it needs:

- A **higher-privileged** permission is accepted in place of the one listed — for example `Group.Read.All` or `Directory.Read.All` for `GroupMember.Read.All`.
- **Signed-in user:** a missing scope stops the run, with the `Connect-MgGraph` command to fix it.
- **App-only** (managed identity, certificate): a missing scope is a warning, because an app can hold an Entitlement Management role instead of the permission. Graph rejects the calls if it has neither.

| Function | Scopes |
|---|---|
| `Export-SiSDistributionList` | `GroupMember.Read.All` — read only |
| `Sync-SiSAccessPackage` | `EntitlementManagement.ReadWrite.All`, `GroupMember.Read.All` |
| `New-SiSAccessPackage` | `EntitlementManagement.ReadWrite.All` |
| `Add-` / `Remove-SiSAccessPackageResource` | `EntitlementManagement.ReadWrite.All` |
| `Get-SiSAccessPackageResourceRole` | `EntitlementManagement.Read.All` (`ReadWrite.All` with `-AddToCatalog`) |
| `Add-` / `Remove-SiSAccessPackageAssignment` | `User.Read.All`, `EntitlementManagement.ReadWrite.All` |
| `Get-SiSGraphUser` | `User.Read.All` |

`GroupMember.Read.All` is used instead of `Group.Read.All`: it covers groups, members and owners, without reading Microsoft 365 group content such as conversations and calendars.

### Check it yourself

Don't take my word for it — every Graph API page lists the least privileged permission for that call, so you can check that the module asks for no more than it needs:

- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference) — every permission and what it grants
- [Overview of Microsoft Graph permissions](https://learn.microsoft.com/graph/permissions-overview) — delegated vs application permissions, and least privilege
- [Entitlement management API](https://learn.microsoft.com/graph/api/resources/entitlementmanagement-overview?view=graph-rest-1.0) — the API the module uses, with links to every call, for example [Create accessPackage](https://learn.microsoft.com/graph/api/entitlementmanagement-post-accesspackages?view=graph-rest-1.0) and [Create accessPackageAssignmentRequest](https://learn.microsoft.com/graph/api/entitlementmanagement-post-assignmentrequests?view=graph-rest-1.0)
- [Delegation and roles in entitlement management](https://learn.microsoft.com/entra/id-governance/entitlement-management-delegate) — the catalog roles below

The role on the catalog limits a run more than the scope does, so if you want to run with as little as possible, start there.

## Roles — what really limits a run

Delegated scopes never give more than the signed-in user's role allows.

- Use the least privileged Entitlement Management role on the specific catalog: **Access package manager** (packages and resources) or **Access package assignment manager** (assignments). Not Identity Governance Administrator, and never Global Administrator.
- Make the role **eligible via PIM** and activate it only for the run.
- Protect admin accounts with Conditional Access and phishing-resistant MFA.
- Adding a resource to a catalog can also require rights on the resource itself (for example group or app owner), depending on how the catalog is set up.

## The Microsoft Graph PowerShell app

An interactive `Connect-MgGraph` without `-ClientId` uses the *Microsoft Graph Command Line Tools* enterprise app. Consent there is **cumulative**: asking for fewer scopes doesn't remove scopes consented earlier, and an admin consent for the organisation applies to everyone who uses the app.

For larger environments:

- Use a dedicated app registration (`Connect-MgGraph -ClientId ... -TenantId ...`) with *assignment required*, so only named admins can sign in, consented only for the scopes above.
- For unattended runs, use a managed identity or a certificate — never a client secret. Give the identity an Entitlement Management role on the specific catalog rather than the tenant-wide `EntitlementManagement.ReadWrite.All` permission where you can.
- Review what's consented under *Enterprise applications → Microsoft Graph Command Line Tools → Permissions*.

## Dependencies

`Microsoft.Graph.Authentication` and `ImportExcel` are `RequiredModules` in the manifest, so they're installed by PowerShellGet from the PowerShell Gallery — with its normal publisher and signature checks — when you install SiSGovernance. The module never installs or imports anything itself while it runs. In locked-down environments, install pinned versions from an internal repository first.

## Input validation

- Id parameters (`-AccessPackageId`, `-AssignmentPolicyId`, `-GroupId`, `-ApplicationId`, `-CatalogId`) are typed `[guid]`, so PowerShell rejects anything that isn't a GUID before the function even starts. Any casing is accepted; ids are always sent to Graph in lowercase.
- Ids read from an Excel file (`ObjectId`, `AccessPackageId`) are checked per row — a value that isn't a GUID makes that row `Invalid`, and it never reaches a Graph URL.
- Names used in OData filters have single quotes escaped, and a `-Filter` you give `Get-SiSGraphUser` is URL-encoded.

## Text from Entra in Excel

Names, addresses and owners in the Excel files come from Entra, where anyone who can rename a group or a user decides the text. A name like `=HYPERLINK(...)` would become a live formula in a report an admin opens (formula injection, CWE-1236). So every value is written as text: text that starts with `=` keeps Excel's quote prefix, and nothing is turned into a clickable link.

## The Excel files are access control

With the distribution list flow, whoever can edit an `ObjectId` in the file decides which list a package grants. `Sync-SiSAccessPackage` checks that it *is* a distribution list — not that it's the *right* one.

- Keep the files somewhere with restricted access (for example SharePoint with a sensitivity label), not on a desktop.
- Have someone else review the `-WhatIf` result and the Bicep change before deploying.

## Personal data

Exports and reports contain names, email addresses and owners' UPNs. Treat them as personal data: store them protected, share them only as needed, and delete old files when they're no longer needed.
