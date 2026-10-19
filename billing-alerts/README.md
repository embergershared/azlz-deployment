# Azure Billing Alerts

Creates (or updates) a **monthly cost budget** on each Azure subscription, with
**email alerts** when actual spend reaches 70%, 80%, 90% and 100% of the budget.

## Files

| File | Purpose |
|---|---|
| `Billing-Alert.ps1` | The script |
| `Billing-Alert.example.psd1` | Template config — copy it for a new environment |

Real environment configs (`Billing-Alert.<environment>.psd1`) contain tenant,
subscription IDs and email addresses: keep them local and add them to `.gitignore`.

## Prerequisites

- PowerShell 7 (`pwsh`)
- `Az.Accounts` and `Az.Resources` modules — installed automatically if missing
- **Cost Management Contributor** (or Contributor) on each subscription

## Usage

1. Copy the template and fill it in:

   ```powershell
   Copy-Item .\Billing-Alert.example.psd1 .\Billing-Alert.<environment>.psd1
   ```

   | Setting | Meaning |
   |---|---|
   | `TenantId` | Tenant of the subscriptions (empty = tenant you are signed in to) |
   | `Subscriptions` | `@{ Id = "..."; Amount = 250; Name = "..." }` per subscription. `Amount` is optional, `Name` is only a label |
   | `EmailAddresses` | Alert recipients |
   | `DefaultBudgetAmount` | Monthly amount when a subscription has no `Amount` (default 100) |
   | `ThresholdPercents` | Alert levels in % of the budget (max 5, default 70/80/90/100) |
   | `BudgetNamePrefix` | Budget name = `<prefix>-<subscription name>` (default `Monthly-Cost-Budget`) |

2. Run it:

   ```powershell
   .\Billing-Alert.ps1 -ConfigFile .\Billing-Alert.<environment>.psd1
   ```

   The script signs you in to the right tenant if needed, then prints a summary table
   with the status of each subscription.

Running again is safe: existing budgets are updated, not duplicated.

### Overriding the config

Any setting can be passed on the command line instead, and wins over the config file:

```powershell
# Send this run's alerts only to you
.\Billing-Alert.ps1 -ConfigFile .\Billing-Alert.contoso.psd1 -EmailAddresses "me@contoso.com"

# No config file at all
.\Billing-Alert.ps1 -TenantId "<tenant-id>" -EmailAddresses "a@contoso.com" `
    -Subscriptions @("<subscription-id>", 250), @("<subscription-id>")
```

### Budgets created with the old names

Earlier versions named budgets after the subscription only (e.g.
`Contoso-Hub-Connectivity`). The script reports them; add
`-RemoveLegacyBudgets` to delete them once the new budget exists, otherwise alerts
are sent twice.

## Checking the result

Azure portal → **Subscriptions** → *subscription* → **Cost Management** → **Budgets**.
Open a budget → **Edit budget** → **Set alerts** to see the thresholds and recipients.
