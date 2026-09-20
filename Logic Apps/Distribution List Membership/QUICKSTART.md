# Quickstart — just the commands

See README.md for the reasoning/details behind any of these steps.

Fill these in once, use them throughout:
- `<RG>` = your resource group
- `<SUB>` = your subscription id
- `<REGION>` = your Azure region (e.g. `swedencentral`)
- `<CATALOG>` = your access package catalog id
- `<TENANT>` = `<yourtenant>.onmicrosoft.com`

The whole setup runs from one script,
`Complete-EntitlementManagementSetup.ps1`: it builds and deploys the Bicep
template, publishes the Function App code, and configures the Entitlement
Management pieces (role assignment, custom extension) as well as the
Exchange Online side (service principal, least-privilege role) — all in a
single run. No separate scripts and no extra tooling (such as Azure
Functions Core Tools) are needed.

---

**1. Create the resource group (if it doesn't exist yet)**
```powershell
New-AzResourceGroup -Name <RG> -Location <REGION>
```

**2. Fill in `bicep\main.bicepparam`**

Open the file directly (it must stay named exactly `main.bicepparam` and
live in `bicep\` — the setup script looks for that exact file). The script
refuses to run if it still finds the words `example` or `access package
guid` anywhere in the file, so replace every placeholder. At minimum, set:
- `location`
- `accessPackageCatalogId`
- `exchangeOnlineOrganization`
- `functionAppName` — must be globally unique across all of Azure; the
  shipped placeholder has "example" in it on purpose, so the script forces
  you to change it
- `distributionListMapping` (access package id → list of DL addresses)

Everything else (`uamiName`, `exchangeRightsUamiName`, `logicAppName`, etc.)
already has a sensible default and only needs changing if you want to
override it.

**3. Run the setup script — from the solution's root folder**

Run it from the same folder that directly contains
`Complete-EntitlementManagementSetup.ps1`, the `bicep\` folder, and the
`function-distributionlist-membership\` folder. The script zips and
publishes the function code using a path relative to your current
directory, so running it from the wrong location means the function code
won't be found (even though the Bicep part would still go through).

You'll be prompted to sign in interactively — once for Azure, once for
Graph, once for Exchange Online:
```powershell
.\Complete-EntitlementManagementSetup.ps1 `
  -SubscriptionId "<SUB>" -ResourceGroup "<RG>" `
  -Organization "<TENANT>" -AccessPackageCatalogId "<CATALOG>"
```

The script signs you in (Azure, Graph, Exchange Online), deploys
`bicep\main.bicep`, publishes the function code, assigns the Entitlement
Management role scoped to the catalog, registers/updates the custom
extension against the Logic App, registers the Exchange-rights identity as
an Exchange Online service principal, and creates/reuses and assigns the
least-privilege Exchange role (`DistributionListMembershipOnly` by default).

**4. Create the access package and wire the custom extension into its
policy**

The script only registers the custom extension on the catalog — it doesn't
create an access package for you, and registering the extension alone
doesn't make anything call it. In the Entra admin center:
1. Under **Identity Governance > Entitlement management > Access packages**,
   create (or open) the access package in this catalog that should manage
   DL membership.
2. Open its **Policies** tab > your policy > **Custom Extensions** tab.
3. Add the registered extension (`Distribution List Membership Extension`
   by default) for the **"When access is granted"** stage.
4. Add it again — separately — for the **"When access is removed"** stage.
5. Make sure the access package's ID is a key in `distributionListMapping`
   in `main.bicepparam` (step 2), otherwise the Logic App won't recognize it.

**5. Test**
Assign (or remove) that access package. Check the distribution list
membership.

---

### Good to know

- Every sign-in is interactive: Azure, Microsoft Graph, and Exchange Online
  each prompt you separately.
- The Function App runs on a classic Windows Consumption plan (Y1), not Flex
  Consumption — deliberate, since publishing happens via `Publish-AzWebApp`,
  which doesn't support Flex Consumption.
- **The Exchange role can take a while to actually work.** Per Microsoft's
  own documentation on RBAC for Applications, permission changes for an app
  (service principal) go through a cache that refreshes somewhere between 30
  minutes and 2 hours after the change, depending on how active that
  identity has been — so right after the setup script finishes, a test
  assignment can still fail with an authorization error even though the role
  was assigned correctly. If that happens, wait and try again rather than
  assuming something is broken. `Test-ServicePrincipalAuthorization` bypasses
  the cache if you want to check the permission immediately instead of
  waiting. ([Microsoft Learn: RBAC for Applications in Exchange
  Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac))

### Changing something later?

Redeploy = run step 3's command again. Nothing needs to be deleted first —
everything is named so a new run updates the same resources.

One exception: a failed test assignment of an access package can't be
retried in place — remove and reassign it to trigger a new attempt (an Entra
limitation, not this solution's).