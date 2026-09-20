# Distribution List Membership Solution — Bicep edition

[➔ Download the Latest Release Assets](https://github.com/irean/EntraGovernance-Scripts/releases/tag/v1.0.0)

This solution reacts to Microsoft Entra ID Governance (Entitlement
Management) access package assignments and removals, and adds or removes the
target user from one or more Exchange Online distribution lists accordingly.
Almost everything is declared as Bicep infrastructure; the handful of pieces
that have no Bicep resource type (the Entitlement Management role
assignment, custom extension registration) plus the Function App code
publish are handled by one PowerShell script,
`Complete-EntitlementManagementSetup.ps1`, which also runs the Bicep
deployment itself. It's the only script you run — see "Setup" below.

## File layout

```
Complete-EntitlementManagementSetup.ps1   - the only script you run. Deploys the Bicep template,
                                             publishes the Function App code, assigns the Entitlement
                                             Management role, registers the custom extension, registers
                                             the Exchange Online service principal, and creates/assigns
                                             the least-privilege Exchange role. See "What the script
                                             does" below.
bicep/
  bicepconfig.json                        - declares the Microsoft Graph Bicep extension
  main.bicep                              - both UAMIs, the Function App Registration/SP/app role
                                             assignment (Graph), and (via modules) the Function App
                                             and the Logic App
  main.bicepparam                         - the parameter file you edit before deploying. The setup
                                             script reads this exact file/path, so keep the name and
                                             location as-is.
  modules/
    functionapp.bicep                     - the Function App itself: classic Windows Consumption
                                             (Y1) plan, deployment storage account, the Function App
                                             resource, and its authentication configuration (authsettingsV2)
    logicapp.bicep                        - the Logic App, including the AADPOP access-control policy
                                             that locks its trigger to Entra ID Governance
function-distributionlist-membership/     - the Function App project root, published by the setup script
  host.json                               - turns on managedDependency so requirements.psd1 below
                                             gets installed automatically on cold start
  requirements.psd1                       - pins ExchangeOnlineManagement 3.x (needed for
                                             Connect-ExchangeOnline -ManagedIdentity) and az.accounts 5.x
  DistributionListMembership/              - the function itself (folder name = function name in the portal)
    function.json
    run.ps1
```

## What lives where, and why

| Piece | Where it lives | Notes |
|---|---|---|
| Logic Apps' User-Assigned Managed Identity | `main.bicep` | Calls the Function App and reports back to Microsoft Graph |
| Dedicated "Exchange rights" User-Assigned Managed Identity | `main.bicep` | Deliberately a *separate* identity from the Logic Apps one, so "can call our Function/Graph" and "can write to Exchange Online" never share a principal. Attached to the Function App and reusable by future Exchange-touching Function Apps |
| Function App's Service Principal (`appRoleAssignmentRequired: true`) | `main.bicep` (`Microsoft.Graph/servicePrincipals`) |  |
| Logic Apps UAMI's app role assignment on the Function | `main.bicep` (`Microsoft.Graph/appRoleAssignedTo`) |  |
| Function App, its plan and storage account | `bicep/modules/functionapp.bicep` | See "Design highlights" below |
| Logic App, incl. its AADPOP trigger lock | `bicep/modules/logicapp.bicep` |  |
| Entitlement Management role assignment on the UAMI, scoped to the catalog | `Complete-EntitlementManagementSetup.ps1` | Not expressible as a Bicep/Graph resource type |
| Custom workflow extension registration on the catalog | `Complete-EntitlementManagementSetup.ps1` | Same reason |
| Function App code publish | `Complete-EntitlementManagementSetup.ps1` | Zips `function-distributionlist-membership\*` and calls `Publish-AzWebApp` |
| Exchange Online service principal registration for the Exchange-rights UAMI | `Complete-EntitlementManagementSetup.ps1` | Registers the identity as an Exchange Online service principal before granting it Exchange rights |
| Least-privilege custom Exchange management role + its assignment | `Complete-EntitlementManagementSetup.ps1` | Created once, reused/kept as-is on later runs |

## Design highlights — simplicity and security

- **No secrets anywhere.** Every app-to-app call in this solution rides on a
  managed identity: the Logic Apps UAMI calls the Function App and reports
  back to Graph, the dedicated Exchange UAMI talks to Exchange Online. There
  is no client secret, certificate, or key to store or rotate for any of
  these calls.
- **Least privilege by design.** The custom Exchange role is trimmed to
  exactly four cmdlets (`Add-DistributionGroupMember`,
  `Remove-DistributionGroupMember`, `Get-DistributionGroupMember`,
  `Get-DistributionGroup`); the Entitlement Management role assignment is
  scoped to just this one access package catalog, not the whole tenant; and
  the Exchange-rights UAMI is kept separate from the Logic Apps UAMI so
  Exchange write rights never piggyback onto an identity used for anything
  else.
- **Locked down at both ends of the call path.** The Function App only
  accepts calls from the Logic Apps UAMI (`appRoleAssignmentRequired: true`
  on its service principal), and the Logic App's trigger only accepts
  requests carrying Entra ID Governance's own AADPOP claims — nothing else
  can invoke either one.
- **One idempotent script drives the whole setup.** Every resource is
  matched by name, `uniqueName`, or `appId`, so running
  `Complete-EntitlementManagementSetup.ps1` again — after changing
  `main.bicepparam`, or just to reconcile drift — is always safe and never
  duplicates anything.

## Prerequisites

This solution is deployed entirely via PowerShell — no Azure CLI (`az`) and
no Azure Functions Core Tools (`func`) are required anywhere; the setup
script publishes the Function App code itself via `Publish-AzWebApp`.

- **PowerShell modules**: `Az.Accounts`, `Az.Resources`,
  `Microsoft.Graph.Authentication`, and `ExchangeOnlineManagement` (3.x or
  later) — all four are declared as hard requirements in the script
  (`#Requires -Modules`); install/update with `Install-Module`. You'll also
  need `Az.Websites`, used indirectly for `Publish-AzWebApp`; it's normally
  installed automatically as part of the `Az` meta-module.
- **Az PowerShell 10.4.0+** for `.bicepparam` file support:
  ```powershell
  (Get-Module -ListAvailable -Name Az.Resources).Version
  ```
- **Bicep CLI, installed standalone.** The setup script checks whether
  `bicep` is on your `PATH`, and if not, looks for it under
  `%USERPROFILE%\.Azure\bin\bicep.exe`; if it can't find it either way, it
  stops with a link to the install instructions. Install it from
  [Microsoft's Bicep install
  docs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install)
  if you don't have it yet.
- **Outbound network access to `mcr.microsoft.com`** — the Microsoft Graph
  Bicep extension is fetched from there as an OCI artifact the first time you
  build/deploy. A blocked network fails with `BCP192: Unable to restore the
  artifact ...`.
- **Permissions**: rights to create resources in the target resource group;
  Global Administrator/Application Administrator-level Entra roles (or
  equivalent) to create app registrations, service principals, and grant
  Entitlement Management roles; and Exchange Administrator/Organization
  Management rights for the (always-interactive) Exchange Online sign-in.

## Setup

**1. Create the resource group, if it doesn't exist yet.**
```powershell
New-AzResourceGroup -Name <your-resource-group> -Location <your-region>
```

**2. Fill in `bicep/main.bicepparam`.**

The setup script refuses to run if it still finds the literal words
`example` or `access package guid` anywhere in this file, so replace every
placeholder before proceeding. At minimum you must set:
- `location`
- `accessPackageCatalogId`
- `exchangeOnlineOrganization`
- `functionAppName` — it becomes part of the Function App's public hostname,
  so it must be globally unique across all of Azure; the shipped placeholder
  (`func-gov-distributionlist-membership-example`) contains the word
  "example" specifically so the script's validation forces you to pick a
  real, unique name here
- `distributionListMapping` (maps each access package ID to the distribution
  list SMTP addresses it should manage)

Everything else in `main.bicep` (`uamiName`, `exchangeRightsUamiName`,
`functionAppRegistrationUniqueName`, `functionAppRoleValue`, `logicAppName`,
`powerShellVersion`, `callbackSourceName`, `governanceCallerAppId`) already
has a sensible default and does not need to be set unless you want to
override it.

**3. Run the setup script — from the solution's root folder.**

Run it from the same folder that directly contains
`Complete-EntitlementManagementSetup.ps1`, the `bicep\` folder, and the
`function-distributionlist-membership\` folder (see the note under
"Behavior notes" below on why this matters).

You'll be prompted to sign in interactively — once for Azure, once for
Microsoft Graph, and once for Exchange Online:
```powershell
.\Complete-EntitlementManagementSetup.ps1 `
  -SubscriptionId "<subscription-id>" -ResourceGroup "<resource-group>" `
  -Organization "<yourtenant>.onmicrosoft.com" -AccessPackageCatalogId "<catalog-id>"
```

Optional parameters you can add:
- `-EntitlementManagementRoleName` — cosmetic display text only (default
  `"Access package assignment manager"`)
- `-EntitlementManagementRoleTemplateId` — override the built-in role's
  template ID if you ever need a different role (default
  `e2182095-804a-4656-ae11-64734e9b7ae5`)
- `-CustomExtensionDisplayName` / `-CustomExtensionDescription`
- `-CustomRoleName` — name of the least-privilege Exchange role the script
  creates (default `DistributionListMembershipOnly`)

**4. Create the access package (if you don't have one yet) and wire the
custom extension into its policy.**

The setup script only registers the custom extension on the catalog — it
does not create an access package for you, and registering the extension
does not automatically make any access package call it. You still need to,
in the Entra admin center:

1. Under **Identity Governance > Entitlement management > Access packages**,
   create the access package in this catalog (or open an existing one) that
   should manage distribution list membership, with at least one resource
   and an assignment policy.
2. Open that access package's **Policies** tab, select the policy, and go to
   its **Custom Extensions** tab.
3. Add the custom extension the script registered (named
   `Distribution List Membership Extension` by default, or whatever you
   passed as `-CustomExtensionDisplayName`) for the **"When access is
   granted"** stage.
4. Add the same custom extension a second time for the **"When access is
   removed"** stage — request and removal stages are configured separately,
   so this is a second, independent step, not a checkbox on the first one.
5. Make sure this access package's ID is a key in `distributionListMapping`
   in `bicep/main.bicepparam` (step 2 above), mapped to the distribution
   lists it should manage — the Logic App silently does nothing for a
   catalog request whose access package ID it doesn't recognize.

The two stages you want are "granted" and "removed", not "request created"
or "request approved" — those fire earlier in the approval workflow, before
there's actually anything to add or remove, and the Function's `run.ps1`
only knows how to handle `Add`/`Remove`, derived from request types that
correspond to a grant or a removal actually happening.

**5. Test end to end.** Assign (or remove) an access package in the catalog
and confirm the distribution list membership updates.

## What the script does, in order

1. Validates that `bicep\main.bicepparam` doesn't still contain placeholder
   values.
2. Confirms the Bicep CLI is available (PATH, then
   `%USERPROFILE%\.Azure\bin`).
3. Authenticates interactively to Azure Resource Manager and sets the
   subscription context.
4. Authenticates interactively to Microsoft Graph with delegated scopes
   `EntitlementManagement.ReadWrite.All` and
   `RoleManagement.ReadWrite.Directory`.
5. Connects to Exchange Online, interactively; sign in with an account that
   has Organization Management / Exchange Administrator rights.
6. Deploys `bicep\main.bicep` with `bicep\main.bicepparam` — this creates or
   updates both UAMIs, the Function App Registration/service
   principal/app-role assignment, the Function App and its plan/storage/auth
   config, and the Logic App with its AADPOP trigger lock.
7. Zips `function-distributionlist-membership\*` and publishes it to the
   Function App with `Publish-AzWebApp`.
8. Assigns the Entitlement Management role (matched by
   `EntitlementManagementRoleTemplateId`) to the Logic Apps UAMI, scoped to
   just this access package catalog.
9. Registers (or updates, if one with the same display name already exists)
   the custom workflow extension on the catalog, pointing at the deployed
   Logic App.
10. Registers the Exchange-rights UAMI as an Exchange Online service
    principal, if it isn't one already.
11. Creates the custom role (copied from `Mail Recipients`, trimmed down to
    `Add-DistributionGroupMember`, `Remove-DistributionGroupMember`,
    `Get-DistributionGroupMember`, `Get-DistributionGroup`) — or, if a role
    with that name already exists, reuses it as-is without re-trimming (in
    case you customized it, e.g. to add cmdlets for another Function sharing
    this identity).
12. Assigns that role to the Exchange-rights UAMI's service principal.
13. Prints the Bicep deployment outputs, the Logic App resource ID, and the
    registered custom extension ID.

## Behavior notes

- **Classic Windows Consumption (Y1) plan, not Flex Consumption.**
  `functionapp.bicep`'s own metadata spells out why: the code is published
  with plain `Publish-AzWebApp` from the setup script, which does not
  support Flex Consumption.
- **Run the script from the solution's root folder.** The Bicep file paths
  are resolved relative to the script's own location (`$PSScriptRoot`), but
  the function code packaging step (`Compress-Archive -Path
  .\function-distributionlist-membership\*`) uses a path relative to your
  current working directory instead. If you `cd` somewhere else before
  running the script, that step can fail to find the function code even
  though the Bicep deployment still works.
- **Every sign-in is interactive.** Azure, Microsoft Graph, and Exchange
  Online each prompt you separately when you run the script.
- **The Exchange role assignment can take a while to actually take effect.**
  Per Microsoft's own documentation on RBAC for Applications, permission
  changes for an app (service principal) are subject to a cache that
  refreshes somewhere between 30 minutes and 2 hours after the change,
  depending on how active that identity has been — the cache for an app
  with no recent inbound API calls resets after 30 minutes, while an active
  app's cache can be kept alive for up to 2 hours. So immediately after the
  setup script finishes, the Function may still get an authorization error
  from Exchange Online even though `Complete-EntitlementManagementSetup.ps1`
  assigned the custom role correctly — this is expected, not a sign that the
  setup failed. `Test-ServicePrincipalAuthorization` bypasses the cache if
  you want to verify the permission immediately instead of waiting.
  ([Microsoft Learn: RBAC for Applications in Exchange
  Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac))
- **Idempotent.** Every resource is matched by name, `uniqueName`, or
  `appId`, so re-running the whole script (after editing
  `main.bicepparam`, or just to reconcile drift) is always safe. The one
  exception: a failed test assignment of an access package can't be retried
  in place — remove and reassign it to trigger a new attempt (an Entra
  limitation, not this solution's).

## Rollback / cleanup

- Delete the resource group to remove the Logic App, both UAMIs, the
  Function App, its plan and storage account:
  ```powershell
  Remove-AzResourceGroup -Name <your-resource-group>
  ```
- Remove the Function App's app registration and service principal:
  ```powershell
  Remove-AzADApplication -ApplicationId <functionAppRegistrationAppId>
  ```
- Remove the custom extension and the Entitlement Management role assignment
  from the catalog via Microsoft Graph if you want a fully clean catalog.
- Remove the Exchange Online custom role assignment and role, and the
  Exchange-rights UAMI's service principal, if you no longer need them
  (`Remove-ManagementRoleAssignment`, `Remove-ManagementRole`,
  `Remove-ServicePrincipal`).