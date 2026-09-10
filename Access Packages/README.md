# Access Packages

PowerShell toolkit for bulk-managing Microsoft Entra ID **Entitlement Management Access Package** assignments via Microsoft Graph — either from a list of users in Excel, or by resolving the target users dynamically with a Graph `$filter` query.

Everything lives in **`ap_add.ps1`**.

## What's in the script

| Function | Purpose |
|---|---|
| `Test-Module` | Checks whether a required module is imported; imports or installs it (`-Scope CurrentUser`) if missing. |
| `ConvertTo-PSCustomObject` | Recursively converts the hashtables returned by `Invoke-MgGraphRequest` into `PSCustomObject`s so results behave like normal PowerShell objects (sortable, filterable, exportable). |
| `igall` | Pages through a Graph API endpoint (`@odata.nextLink`) and returns every result. Pass `-Eventual` to add the `ConsistencyLevel: eventual` header, required for advanced queries (`$count`, `startsWith`, multi-clause filters, etc.). |
| `Select-FolderPath` | Opens a Windows folder-picker dialog so the user can choose where the results export should be saved. |
| `Invoke-AccessPackageOperation` | Core worker: resolves each user by UPN and submits an `adminAdd` or `adminRemove` request against `identityGovernance/entitlementManagement/assignmentRequests`. Used by both entry points below. |
| `Start-BulkAddUsersToAccessPackage` | Entry point #1 — reads users from an **Excel file** (must have a `userPrincipalName` column) and adds/removes them from an Access Package. |
| `Get-GraphUsersByFilter` | Runs an OData `$filter` query against `/v1.0/users` (with `ConsistencyLevel: eventual` on by default) and returns the matching users. |
| `Start-BulkAccessPackageOperationByFilter` | Entry point #2 — resolves target users with a Graph filter instead of Excel, then adds/removes them the same way. Includes a `-MaxUsers` safety cap and a `-PreviewOnly` switch. |

Both entry points validate the Access Package and Assignment Policy IDs, ask for an explicit `yes` before making any changes, and export a results file (`UserPrincipalName`, `DisplayName`, `ObjectId`, `Status`, `Error`) to a folder you choose.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+
- Modules (auto-installed on first run if missing): `Microsoft.Graph.Authentication`, `ImportExcel`
- A Microsoft Entra ID account with rights to consent to and use:
  - `User.Read.All`
  - `EntitlementManagement.ReadWrite.All`

## Usage

### Option A — bulk add/remove from an Excel file

```powershell
Start-BulkAddUsersToAccessPackage `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -ExcelPath "C:\users.xlsx" `
    -AdminAdd
```

The Excel file needs a `userPrincipalName` column. Add `-AdminRemove` instead of `-AdminAdd` to remove users, and `-BypassApproval` to attempt to skip the assignment policy's approval step (only takes effect if the policy itself allows bypass).

### Option B — bulk add/remove by Graph filter

Useful when the target group can be described by a directory attribute (department, employee type, account status, name pattern, etc.) instead of a static list.

```powershell
# Preview who the filter matches before touching anything
Start-BulkAccessPackageOperationByFilter `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -Filter "userType eq 'Member' and employeeType eq 'employee'" `
    -AdminAdd `
    -PreviewOnly

# Run it for real
Start-BulkAccessPackageOperationByFilter `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -Filter "userType eq 'Member' and employeeType eq 'employee'" `
    -AdminAdd
```

`-MaxUsers` (default `500`) stops the run if the filter matches more users than expected — raise it explicitly if a broader run is intentional.

You can also call `Get-GraphUsersByFilter` directly to just inspect who a filter matches, e.g. to check what values actually exist for an attribute before building a filter against it:

```powershell
Get-GraphUsersByFilter -Filter "userType eq 'Member'" -Select "employeeType" |
    Select-Object -ExpandProperty employeeType -Unique
```

### Calling Graph directly with `igall` (advanced)

For one-off queries you can call `igall` directly instead of going through `Get-GraphUsersByFilter`. Because PowerShell interpolates `$` inside double-quoted strings, any literal `$filter`, `$select`, or `$count` in the URL needs a backtick immediately in front of it — including right after an `&`:

```powershell
igall "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Member' and employeeType eq 'employee'&`$count=true" -Eventual
```

Forgetting a single backtick (or accidentally typing an accent character `´` instead of a backtick `` ` ``) silently breaks the query — Graph just ignores the malformed parameter instead of erroring, so it looks like the filter "did nothing." If you'd rather avoid this entirely, use a fully single-quoted string (doubling any inner single quotes) or just use `Get-GraphUsersByFilter`, which builds the URL for you.

## Output

Both entry points export an `.xlsx` file named `<Add|Remove>[-ByFilter]-<AccessPackageName>-<yyyy-MM-dd>.xlsx` to the folder you pick, with one row per user and its submission status.

## Notes

- `-BypassApproval` only has an effect if the target Assignment Policy is configured to allow it; a policy that enforces mandatory approval will still route the request through approval.
- Filtering on `employeeType` (and other free-text HR-sourced attributes) is exact-match and case-sensitive-ish in practice — check actual values in your tenant with `Get-GraphUsersByFilter` before relying on a specific casing.

## Author

Sandra Saluti