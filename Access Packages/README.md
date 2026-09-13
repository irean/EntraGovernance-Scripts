# Access Packages

PowerShell toolkit for managing Microsoft Entra ID **Entitlement Management Access Package** assignments via Microsoft Graph — one user, an Excel list, or a `$filter` query, all through the same flow.

Everything lives in **`ap_add.ps1`**.

## v2: one entry point instead of three

The previous version had a separate function per input source, each duplicating its own connect/validate/export logic, and no single-user shortcut. It's now one public function:

```powershell
Invoke-AccessPackageAssignment
```

| Old (v1) | New (v2) |
|---|---|
| `Start-BulkAddUsersToAccessPackage -ExcelPath ...` | `Invoke-AccessPackageAssignment -ExcelPath ...` |
| `Start-BulkAccessPackageOperationByFilter -Filter ...` | `Invoke-AccessPackageAssignment -Filter ...` |
| *(no equivalent — needed Excel or a filter for even one person)* | `Invoke-AccessPackageAssignment -UserPrincipalName "one@epicalgroup.com"` |

What else changed:

- **Batching.** Assignment requests (and UPN → user-id lookups) are sent via Microsoft Graph JSON batching (`$batch`, up to 20 requests per HTTP call) instead of one Graph call per user.
- **Already-assigned / not-assigned detection.** `-AdminAdd` and `-AdminRemove` are handled differently here, because Graph itself treats them differently (see below). A user who already has the assignment (`-AdminAdd`) or has nothing to remove (`-AdminRemove`) is never left looking like a generic failure — it's reported as `AlreadyAssigned` or `NotAssigned`.
- **Report is opt-out, not automatic.** Add `-SkipReport` to get the results object back directly (e.g. for a quick single-user run) instead of always being prompted for an export folder.

## adminAdd and adminRemove are not symmetric

This tripped up an earlier version of the script, so it's worth calling out explicitly.

Graph's `accessPackageAssignmentRequest` body is shaped differently depending on `requestType`:

- **`adminAdd`** needs `accessPackageId`, `assignmentPolicyId`, and a `target` (the user). There's no pre-check before submitting: every user goes straight into the batch, and if one already has the assignment, Graph rejects it with `409 InvalidRequestExistingGrant`, which the script reads back as `AlreadyAssigned`. Cheaper than fetching every existing assignment first just to avoid a POST Graph would reject anyway.
- **`adminRemove`** needs only the existing `accessPackageAssignment`'s own `id` — there is no other way to tell Graph which assignment to remove. So before an `adminRemove` run, `Resolve-AccessPackageAssignmentIds` fetches current assignments for the Access Package once (filtered to `state eq 'Delivered'`, so an expired assignment's `id` is never picked up in place of the active one), and maps each target user to their assignment `id`. A user with no matching assignment is reported as `NotAssigned` and never submitted at all.

Either way, if a request (add or remove) is already pending for a target, Graph returns `400 InvalidRequest` with a details code of `ExistingOpenRequest`, which the script reports as `OpenRequestExists`.

## What's in the script

| Function | Purpose |
|---|---|
| `Invoke-AccessPackageAssignment` | **The entry point.** Adds or removes users from an Access Package, sourcing them from `-ExcelPath`, `-Filter`, or `-UserPrincipalName`. |
| `Get-GraphUsersByFilter` | Standalone helper: runs an OData `$filter` query against `/v1.0/users` and returns the matches. Also used internally by the entry point's `-Filter` mode. |
| `Resolve-AccessPackageAssignmentIds` | Used only for `-AdminRemove`: resolves each target user to their existing `accessPackageAssignment` id (state-filtered to `Delivered`), since that id is the only thing Graph accepts for removal. |
| `Test-Module`, `ConvertTo-PSCustomObject`, `igall`, `Select-FolderPath` | Unchanged from v1 — module bootstrapping, Graph paging, and the export-folder picker. |
| `Connect-EntraGovernanceGraph`, `Resolve-AccessPackageContext`, `Resolve-AccessPackageTargetUsers`, `Invoke-AccessPackageBatchOperation`, `Resolve-UsersByUpn`, `Invoke-GraphBatch` | Internal helpers behind the entry point. Not usually called directly, but each is independently usable if needed (e.g. `Invoke-GraphBatch` for any other bulk Graph job). |

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+
- Modules (auto-installed on first run if missing): `Microsoft.Graph.Authentication`, `ImportExcel`
- A Microsoft Entra ID account with rights to consent to and use:
  - `User.Read.All`
  - `EntitlementManagement.ReadWrite.All`

## Usage

### A single user — no Excel file, no filter, no report popup

```powershell
Invoke-AccessPackageAssignment `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -UserPrincipalName "anna@epicalgroup.com" `
    -AdminAdd -SkipReport
```

Takes one UPN or several: `-UserPrincipalName "a@epicalgroup.com","b@epicalgroup.com"`.

### From an Excel file

```powershell
Invoke-AccessPackageAssignment `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -ExcelPath "C:\users.xlsx" `
    -AdminAdd
```

The Excel file needs a `userPrincipalName` column. Add `-AdminRemove` instead of `-AdminAdd` to remove users, and `-BypassApproval` to attempt to skip the assignment policy's approval step (only takes effect if the policy itself allows bypass).

### By Graph filter

```powershell
# Preview who the filter matches before touching anything
Invoke-AccessPackageAssignment `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -Filter "userType eq 'Member' and employeeType eq 'employee'" `
    -AdminAdd -PreviewOnly

# Run it for real
Invoke-AccessPackageAssignment `
    -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
    -AssignmentPolicyId "929sio0q99ww" `
    -Filter "userType eq 'Member' and employeeType eq 'employee'" `
    -AdminAdd
```

`-MaxUsers` (default `500`) stops the run if the input matches more users than expected — raise it explicitly if a broader run is intentional. `-PreviewOnly` and `-MaxUsers` work with all three input modes, not just `-Filter`.

You can also call `Get-GraphUsersByFilter` directly to just inspect who a filter matches, e.g. to check what values actually exist for an attribute before building a filter against it:

```powershell
Get-GraphUsersByFilter -Filter "userType eq 'Member'" -Select "employeeType" |
    Select-Object -ExpandProperty employeeType -Unique
```

## Output

`Invoke-AccessPackageAssignment` always returns a results array (`UserPrincipalName`, `DisplayName`, `ObjectId`, `Status`, `Error`), whether or not a report is exported. `Status` is one of:

- `Submitted` — the request was sent to Graph.
- `AlreadyAssigned` — the user already had the assignment; caught from Graph's own response (adminAdd only).
- `NotAssigned` — the user had nothing to remove; caught before submission by the assignment-id lookup (adminRemove only).
- `OpenRequestExists` — a request for this user/access package is already pending (add or remove).
- `Failed` — Graph rejected the request for some other reason; see the `Error` column.
- `Failed - User not found` — the UPN didn't resolve to a user in the tenant.

The full results list is always printed to the terminal first. Unless `-SkipReport` is specified, it's then also exported to `<Add|Remove>-<AccessPackageName>-<yyyy-MM-dd>.xlsx` in a folder you pick. After that, a run summary prints last: a count per status (`Submitted` shown as `Success` in this summary only — the underlying `Status` value is untouched), and for any `Failed` counts, a further breakdown by the actual error message, so "5 failed" doesn't hide that it might be two unrelated problems.

### Calling Graph directly with `igall` (advanced)

For one-off queries you can call `igall` directly instead of going through `Get-GraphUsersByFilter`. Because PowerShell interpolates `$` inside double-quoted strings, any literal `$filter`, `$select`, `$count`, or `$batch` in the URL needs a backtick immediately in front of it — including right after an `&`:

```powershell
igall "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Member' and employeeType eq 'employee'&`$count=true" -Eventual
```

Forgetting a single backtick (or typing an accent character `´` instead of a backtick `` ` ``) silently breaks the query — Graph just ignores the malformed parameter instead of erroring. If you'd rather avoid this entirely, use a fully single-quoted string (doubling any inner single quotes) or just use `Get-GraphUsersByFilter` / `Invoke-AccessPackageAssignment`, which build the URLs for you.

## Notes

- `-BypassApproval` adds a justification note to the request. In practice it likely has no functional effect either way: Microsoft's Entitlement Management API bypasses approval automatically for every `adminAdd` request regardless of this switch, so there's currently nothing for `-BypassApproval` to actually toggle. Flagged here rather than silently relied on — if you need this to matter, it needs a closer look before you depend on it.
- Filtering on `employeeType` (and other free-text HR-sourced attributes) is exact-match; check actual values in your tenant with `Get-GraphUsersByFilter` before relying on a specific casing.
- **adminAdd** has no pre-check at all — every user is submitted, and a duplicate is caught purely from Graph's response (`409 InvalidRequestExistingGrant` → `AlreadyAssigned`), confirmed against real responses, not guessed.
- **adminRemove** does look up the existing assignment id once, right before submission, filtered to `state eq 'Delivered'` so an expired assignment is never mistaken for the active one. That lookup is still a point-in-time snapshot: if someone's assignment is removed in the moment between the lookup and the batch call, Graph rejects it with `404 InvalidRequestNoActiveGrant`, which is caught and reported as `NotAssigned` rather than a generic failure.

## Author

Sandra Saluti