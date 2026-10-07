# Distribution lists → access packages

Step by step: from Exchange Online distribution lists to access packages, so list membership is requested, approved and reviewed in Entitlement Management.

A distribution list can't be a resource in an access package. So these packages are **empty**, and a Logic App + Azure Function adds and removes the list membership when an assignment is granted or removed — the [Distribution List Membership](../../Logic%20Apps/Distribution%20List%20Membership) solution. Its configuration maps each access package to its lists.

| Step | With |
|---|---|
| 1. Export the distribution lists | `Export-SiSDistributionList` |
| 2. Review names and descriptions | Excel, together with the business / HR |
| 3. Create the access packages and the mapping | `Sync-SiSAccessPackage` |
| 4. Deploy the Logic App with the mapping | Distribution List Membership solution |
| 5. Add assignment policies with the custom extension | Entra admin center |
| 6. Migrate existing members | `Add-SiSAccessPackageAssignment` |
| 7. Lock the lists | Exchange Online |

## 1. Export

```powershell
Export-SiSDistributionList

# Without the folder dialog
Export-SiSDistributionList -OutputPath .\Results
```

Read only. Exports every distribution list (mail-enabled, not security-enabled, not a Microsoft 365 group) to `DistributionLists-<timestamp>.xlsx`. The output folder is chosen first — with `-OutputPath`, or in the dialog that opens before anything else happens. Mail-enabled security groups aren't included, and dynamic distribution lists don't exist in Graph at all.

| Column | Filled by |
|---|---|
| `ObjectId`, `DisplayName`, `PrimarySmtpAddress`, `OnPremisesSyncEnabled`, `MemberCount`, `Owners` | The export |
| `Include`, `AccessPackageDisplayName`, `AccessPackageDescription`, `ScopingNotes` | You |
| `AccessPackageId`, `Status`, `StatusMessage` | `Sync-SiSAccessPackage` |

- Lists synced from on-premises (`OnPremisesSyncEnabled = TRUE`) can't be managed by Exchange Online — they're rejected in step 3.
- `Owners` comes from Graph and doesn't always match `ManagedBy` in Exchange.

## 2. Review

Fill in per row:

- **`Include`** — `Yes` or `No` (dropdown). **Only `Yes` rows are processed**; empty means skipped.
- **`AccessPackageDisplayName`** — following your naming standard. Rows with the **same name become one package** with several lists.
- **`AccessPackageDescription`** — shown to users in My Access. Rows for the same package must have the same description.
- **`ScopingNotes`** — free text: who should be able to request it, who approves. You'll use it in step 5; no function reads it.

You can add your own columns — they're kept as-is.

> A package grants **all** its lists. Put several lists behind one package only if everybody should be in all of them.

## 3. Create the access packages

```powershell
# Check first
Sync-SiSAccessPackage -ExcelPath .\DistributionLists.xlsx -CatalogName "Distribution Lists" -WhatIf

# Then for real, with the mapping for the Logic App
Sync-SiSAccessPackage -ExcelPath .\DistributionLists.xlsx -CatalogName "Distribution Lists" -BicepOutput

# Without the folder dialog
Sync-SiSAccessPackage -ExcelPath .\DistributionLists.xlsx -CatalogName "Distribution Lists" -BicepOutput -OutputPath .\Results

# Unattended: no dialog and no confirmation
Sync-SiSAccessPackage -ExcelPath .\DistributionLists.xlsx -CatalogName "Distribution Lists" -BicepOutput -OutputPath .\Results -Confirm:$false
```

Use the catalog the Logic App's custom extension will be registered on.

The whole file is validated first and every problem reported at once. If any row is `Invalid`, nothing is changed and the run ends with an error — fix the rows and run again.

| `Status` | Meaning |
|---|---|
| `Created` | New access package; id written back |
| `Linked` | A package with that name already existed in the catalog — id written back, no duplicate |
| `Updated` | Id set; name or description changed |
| `Unchanged` | Id set; nothing to change |
| `NotFound` | Id set, but the package no longer exists |
| `CatalogMismatch` | Id set, but the package is in another catalog |
| `Skipped` | `Include` isn't `Yes` |
| `Invalid` | Failed validation — see `StatusMessage` |
| `Failed` | Graph rejected the change — see `StatusMessage` |
| `NotProcessed` | The run stopped before this row |

The results go to a new file (`AccessPackages-<catalog>-<timestamp>.xlsx`) — your input file is never overwritten. The output folder is chosen before anything else happens: give it with `-OutputPath`, or pick it in the dialog that opens first. Either way, the run doesn't stop halfway to ask. **Use the results file as input next time**: rows with an id are only compared, so re-running is safe, and that's also how you rename or update descriptions later.

With `-BicepOutput` you also get `distributionListMapping-<catalog>-<timestamp>.bicepparam`:

```bicep
param distributionListMapping = {
  // Mail - Sales
  '<access-package-id>': [
    'sales-se@contoso.com'
    'sales-no@contoso.com'
  ]
}
```

It replaces the **whole** block, so the Excel file must contain every list that should be in the mapping.

## 4. Deploy the Logic App

Paste the block into `main.bicepparam` of the Distribution List Membership solution and run its setup script. Make sure `accessPackageCatalogId` there, and `-AccessPackageCatalogId` of the setup script, are the same catalog as in step 3. See that solution's README.

## 5. Add policies

SiSGovernance doesn't create policies yet — do this in the Entra admin center, per package (*Identity Governance → Access packages → package → Policies*), based on `ScopingNotes`:

1. Who can request, who approves, expiration and access reviews.
2. **Custom extensions:** add the Distribution List Membership extension on **both** stages — *Assignment is granted* and *Assignment is removed*. Without both, nothing happens to the list, and no error tells you.

## 6. Migrate existing members

Assign the people who are already in each list, so the package becomes the truth. Get the list's user members from Graph and pipe them in:

```powershell
$dlId     = '<distribution list ObjectId>'
$apId     = '<access package id>'
$policyId = '<assignment policy id>'

# User members only - contacts and nested groups are left out by the cast
$uri = "https://graph.microsoft.com/v1.0/groups/$dlId/members/microsoft.graph.user?`$select=userPrincipalName&`$top=999"
$upns = do {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    $page.value.userPrincipalName
    $uri = $page.'@odata.nextLink'
} while ($uri)

$upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId -WhatIf
$upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId
```

Before you migrate many users:

- **Every assignment triggers the Logic App.** The Function treats *already a member* as success, so it's safe — but thousands of assignments are thousands of Logic App runs and Exchange connections. For large lists, consider a separate migration policy with the custom extension on *Assignment is removed* only: nothing happens in Exchange during the migration, but removal still takes people off the list.
- **A package grants all its lists.** Migrating members of one list gives them every list behind the package.
- **Contacts and nested groups** in the list can't get assignments — handle them separately.
- **Expiration:** if the policy expires assignments, everybody migrated on the same day expires on the same day.

## 7. Lock the lists

Once the package is the way in, make sure nobody adds members directly in Exchange — otherwise the list and the package drift apart. Close self-service join and review who owns the list (`ManagedBy`).
