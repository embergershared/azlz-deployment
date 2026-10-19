# Billing-Alert.ps1 config - TEMPLATE
# Copy to Billing-Alert.<environment>.psd1, fill in, then run:
#   .\Billing-Alert.ps1 -ConfigFile .\Billing-Alert.<environment>.psd1
@{
    # Microsoft Entra tenant of the subscriptions.
    # Empty = use the tenant of the current Azure context.
    TenantId            = "00000000-0000-0000-0000-000000000000"

    # Used when a subscription has no Amount
    DefaultBudgetAmount = 100

    # Alert thresholds, in percent of the budget amount (max 5)
    ThresholdPercents   = @(70, 80, 90, 100)

    # Budget name = <prefix>-<subscription name>
    # e.g. Monthly-Cost-Budget-Contoso-Connectivity
    BudgetNamePrefix    = "Monthly-Cost-Budget"

    EmailAddresses      = @(
        "finops@contoso.com"
        "platform-lead@contoso.com"
    )

    # Amount is optional (DefaultBudgetAmount is used when omitted).
    # Name is for readability only.
    # BudgetName is optional and replaces <prefix>-<subscription name>.
    Subscriptions       = @(
        @{ Id = "11111111-1111-1111-1111-111111111111"; Amount = 500; Name = "Contoso Connectivity" }
        @{ Id = "22222222-2222-2222-2222-222222222222";               Name = "Contoso Sandbox" }
        @{ Id = "33333333-3333-3333-3333-333333333333"; Amount = 50;  Name = "Contoso Dev"; BudgetName = "Contoso-Dev-Team-Budget" }
    )
}
