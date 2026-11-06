# Deploy-Platform.ps1 config - TEMPLATE
# Copy to Platform.<environment>.psd1, fill in, then run:
#   .\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1             # what-if
#   .\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1 -Mode Deploy
@{
    # Microsoft Entra tenant of the subscriptions.
    # Empty = use the tenant of the current az CLI login.
    TenantId                   = "00000000-0000-0000-0000-000000000000"

    # Platform subscriptions. Placing them in the management / connectivity
    # management groups is done by the governance repository.
    ManagementSubscriptionId   = "11111111-1111-1111-1111-111111111111"
    ConnectivitySubscriptionId = "22222222-2222-2222-2222-222222222222"

    # First = primary region (logging, vWAN, DDoS plan). Add a second region
    # for a second hub (peered / connected to the first one).
    Locations                  = @("swedencentral")

    # Resource names: rg-<token>-logging-<location>, law-<token>-<location>,
    # vnet-<token>-<location>, ... (matches the ALZ defaults when "alz")
    NameToken                  = "alz"

    # hubNetworking | vwanConnectivity | none
    NetworkType                = "hubNetworking"

    # Lock on every resource: None | CanNotDelete | ReadOnly
    ResourceLockKind           = "None"

    # AVM usage telemetry (no customer data, see aka.ms/avm/telemetry)
    EnableTelemetry            = $true

    # Each component is a deployment stack. What happens, on the next Deploy,
    # to a resource that left the templates (e.g. the DNS Private Resolver
    # after DeployDnsPrivateResolver = $false):
    #   deleteAll        delete it, and its resource group when the templates created it
    #   deleteResources  delete it, keep the resource group
    #   detachAll        keep it, the stack just stops managing it
    StackActionOnUnmanage      = "deleteAll"

    # Deny assignment on the stack's resources: none | denyDelete | denyWriteAndDelete.
    # Anything but none needs the "Azure Deployment Stack Owner" role.
    StackDenySettingsMode      = "none"

    Tags                       = @{
        Environment = "prod"
        Workload    = "platform-landing-zone"
        Owner       = "platform-team@contoso.com"
    }

    # --------------------------------------------------------------
    # Management subscription (Log Analytics, DCRs, AMA identity)
    # --------------------------------------------------------------
    Management                 = @{
        LogRetentionInDays      = 365

        # Daily ingestion cap in GB ($null = no cap)
        DailyQuotaGb            = $null

        # Add "SecurityInsights" to onboard Microsoft Sentinel
        Solutions               = @("ChangeTracking")

        DeployAutomationAccount = $false
    }

    # --------------------------------------------------------------
    # Connectivity subscription (used by the NetworkType template)
    # Gateways, Bastion and DDoS are the big cost items: off unless needed.
    # --------------------------------------------------------------
    Connectivity               = @{
        # One per location, same order as Locations.
        # Hub networking: /24 or larger; vWAN virtual hub: /23 or larger.
        HubAddressPrefixes        = @("10.0.0.0/22")

        # vWAN only: VNet next to each virtual hub for Bastion / DNS resolver
        SidecarAddressPrefixes    = @("10.0.4.0/22")

        DeployAzureFirewall       = $true
        # Basic | Standard | Premium. Basic has no DNS proxy: with hub
        # networking it needs DeployDnsPrivateResolver = $false.
        AzureFirewallSku          = "Standard"

        DeployPrivateDnsZones     = $true
        DeployDnsPrivateResolver  = $true

        DeployBastion             = $false
        BastionSku                = "Standard"
        # Instances (host scaling): 2-50 on Standard or higher, Basic is fixed at 2.
        # Each instance adds 20 RDP / 40 SSH sessions, and cost. Changing it later
        # disconnects the active Bastion sessions. Absent = upstream default
        # (4 with hub networking, 2 with vWAN).
        BastionScaleUnits         = 2

        DeployVpnGateway          = $false
        VpnGatewaySku             = "VpnGw1AZ"          # hub networking only
        VpnGatewayMode            = "activeActiveBgp"   # hub networking only
        VpnGatewayAsn             = 65515               # hub networking only

        DeployExpressRouteGateway = $false

        # Primary region only, protects the hub VNets of all regions.
        # The ALZ "Enable-DDoS-VNET" policy assignment needs this plan's ID.
        DeployDdosProtectionPlan  = $false
    }
}
