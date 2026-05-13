# Password Reset Logic App

Deploys an Azure Logic App for automated password resets, wired into Entra ID Lifecycle Workflows as a custom task extension.

Built to handle the part Microsoft's documentation skips — the actual deployment, managed identity setup, Graph permissions, authorization policy, and custom extension registration, all in one script.

Related blog post at [agderinthe.cloud](https://agderinthe.cloud/author/sandra/)

---

## What it does

**Onboarding** — when triggered by a joiner Lifecycle Workflow on the employee's hire date:

- Generates a temporary password and resets the account with `forceChangePasswordNextSignIn: true`
- Sends the password to the manager via email
- Waits a configurable period (default 5 days) and checks whether the user has logged in **and** `forceChangePasswordNextSignIn` is now false — meaning the user changed it themselves
- If not: resets to a new unknown password and notifies the manager to contact the service desk

**Offboarding** — when triggered by a leaver Lifecycle Workflow:

- Resets to an unknown password nobody has
- Revokes all active sign-in sessions
- No email sent, no credential goes anywhere

The `Is Onboarding Workflow` condition routes calls to the correct branch based on which workflow triggered it. The same Logic App handles both scenarios.

---

## Files

| File | Description |
|---|---|
| `Deploy-PasswordResetLogicApp.ps1` | Full deployment script — see below for what it does |
| `LogicApp.json` | Logic App workflow definition template |

---

## What the script does

1. Deploys the Logic App via ARM REST API with System-assigned Managed Identity
2. Connects to Microsoft Graph using the existing Azure token — no second login prompt
3. Assigns required Graph API permissions to the managed identity
4. Assigns the **User Administrator** Entra ID role — required for password reset via `passwordProfile`
5. Configures the `AzureADLifecycleWorkflowsAuthPOPAuthPolicy` authorization policy via full ARM PUT
6. Disables SAS authentication on the Logic App trigger
7. Registers the Logic App as a custom task extension in Lifecycle Workflows
8. On update runs: reuses the existing managed identity principal ID

---

## Prerequisites

- PowerShell 7+
- `Az.Accounts`, `Az.Resources`, `Az.LogicApp` modules
- `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`, `Microsoft.Graph.Identity.DirectoryManagement` modules
- An existing Resource Group
- A mailbox in Exchange Online for the sender address
- Entra ID P1 or P2 — required for `signInActivity`
- The account running the script needs: Contributor on the Resource Group, `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `LifecycleWorkflows.ReadWrite.All`

---

## Quick start

```powershell
. .\Deploy-PasswordResetLogicApp.ps1

Deploy-PasswordResetLogicApp `
    -SubscriptionId  "<subscription-id>" `
    -ResourceGroup   "rg-entra-governance-prod" `
    -LogicAppName    "la-Password-Reset" `
    -Location        "swedencentral" `
    -MailSender      "governance@contoso.com" `
    -OnboardingWorkflowIds @("<lifecycle-workflow-id>")
```

Optional parameters:

| Parameter | Default | Description |
|---|---|---|
| `-CustomExtensionDisplayName` | `Password Reset Extension` | Display name for the custom task extension |
| `-CustomExtensionDescription` | *(auto)* | Description for the custom task extension |
| `-LogicAppDefinitionPath` | `.\LogicApp.json` | Path to the Logic App JSON definition |
| `-TenantId` | *(resolved from context)* | Tenant ID — resolved automatically from Azure context if not provided |
| `-AppId` + `-CertificateThumbprint` | *(optional)* | Service principal auth — omit for interactive login |

---

## Graph permissions assigned to the Logic App

| Permission | Purpose |
|---|---|
| `Mail.Send` | Send email to manager |
| `User.ReadWrite.All` | Read and write user profiles |
| `User-PasswordProfile.ReadWrite.All` | Reset password via `passwordProfile` |
| `UserAuthenticationMethod.ReadWrite.All` | Reset authentication methods |
| `AuditLog.Read.All` | Read `signInActivity` — requires Entra ID P1/P2 |
| `User.RevokeSessions.All` | Revoke active sessions on offboarding |

The managed identity is also assigned the **User Administrator** Entra ID role, which is required for password resets via Graph API regardless of app permissions.

---

## After deployment

The script registers the Logic App as a custom task extension automatically. The only manual step is adding the **Run a custom task extension** task to your Lifecycle Workflow in the Entra portal and selecting the registered extension. Set the task behavior to **Launch and continue**.

---

## Configuring the Logic App

Most changes can be made directly in the Logic App designer without redeploying.

**Changing the wait period** — click `Wait For Login Period` and change the duration. 5 hours for tight security, 7 days for global organizations with multiple time zones.

**Adding a new onboarding workflow ID** — click the `Is Onboarding Workflow` condition, add a new OR row, use the expression `triggerBody()?['data']?['workflow']?['id']` on the left side and paste the new workflow ID on the right.

**Adding offboarding actions** — the False branch already includes reset to unknown password and revoke sessions. Add further steps as needed for your leaver process.

---

## Swapping the delivery mechanism

The password is delivered to the manager via email by default. This is a starting point, not a recommendation. The delivery step is a single HTTP action in the Logic App — swapping it requires no changes to anything else.

Alternatives:
- **Enterprise password manager** (1Password, Bitwarden) — POST to their REST API, write to a vault the manager has access to
- **SMS directly to the employee** — any SMS gateway with a REST API (Twilio, Azure Communication Services)
- **Temporary Access Pass** — for passwordless environments only (cloud-only, Entra-joined devices)

---

## Author

**Sandra Saluti** — Identity & Governance Consultant at Epical  
[LinkedIn](https://www.linkedin.com/in/sandra-saluti-6866a686/) · [Blog](https://agderinthe.cloud/author/sandra/)