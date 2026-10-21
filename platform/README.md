# Platform Landing Zone - Management & Connectivity

Deploys the **Management** and **Connectivity** platform subscriptions of an
Azure Landing Zone with the templates of the
[ALZ Bicep Accelerator](https://github.com/Azure/alz-bicep-accelerator)
(Azure Verified Modules), wrapped with our own parameters and deployment script.

Management groups, policy definitions and assignments are **not** deployed here:
they come from the separate governance repository. This folder produces the
resource IDs those policy assignments need (see [Governance inputs](#governance-inputs)).

## How it works

```text
Platform.<env>.psd1 ──► Deploy-Platform.ps1 ──► ALZ_* environment variables
                                                    │
         params\*.bicepparam  (readEnvironmentVariable)  ◄┘
                │  using
                ▼
         upstream\alz-bicep-accelerator\templates\...   (vendored, pinned tag)
                │
                ▼
         az deployment sub what-if | validate | create
```

| Component | Subscription | Upstream template | Our parameters |
|---|---|---|---|
| Management | `ManagementSubscriptionId` | `templates/core/logging` | [params/management.bicepparam](params/management.bicepparam) |
| Connectivity (`NetworkType = hubNetworking`) | `ConnectivitySubscriptionId` | `templates/networking/hubnetworking` | [params/connectivity-hubnetworking.bicepparam](params/connectivity-hubnetworking.bicepparam) |
| Connectivity (`NetworkType = vwanConnectivity`) | `ConnectivitySubscriptionId` | `templates/networking/virtualwan` | [params/connectivity-virtualwan.bicepparam](params/connectivity-virtualwan.bicepparam) |

### What gets deployed

**Management** - `rg-<token>-logging-<primary>`: Log Analytics workspace
(+ ChangeTracking solution, optional Sentinel), the three data collection rules
(VM Insights, Change Tracking, Defender for SQL), the user-assigned identity used
by the Azure Monitor Agent, and optionally an Automation account.

**Connectivity** - one hub per location (primary first):

- `rg-<token>-conn-<loc>`: hub VNet (or vWAN virtual hub + sidecar VNet), Azure
  Firewall + policy, route tables, and when enabled Bastion, VPN / ExpressRoute
  gateways, DDoS protection plan (primary region only)
- `rg-<token>-dns-<loc>`: Private Link private DNS zones (all zones in the primary
  hub, regional zones in the others), linked to every hub
- `rg-<token>-dnspr-<loc>`: DNS Private Resolver. The hub VNet DNS points to the
  firewall (DNS proxy), which forwards to the resolver inbound endpoint

Hub subnets are derived from each hub's address prefix (first /24):
`AzureFirewallSubnet` .0/26, `AzureBastionSubnet` .64/26, `GatewaySubnet` .128/27,
resolver inbound .160/28 and outbound .176/28, `AzureFirewallManagementSubnet` .192/26.

Bastion, VPN / ExpressRoute gateways and the DDoS plan default to **off**:
they are the large cost items, enable them in the config when needed.

## Prerequisites

- PowerShell 7 (`pwsh`)
- Azure CLI 2.53+ (`az bicep` is used to compile the `.bicepparam` files)
- Owner (or Contributor + User Access Administrator) on both platform subscriptions
- Subscriptions already placed in their management groups by the governance repository
  (recommended, so the platform policies apply from the first deployment)

## Usage

1. Create the environment config (kept out of git, see `.gitignore`):

   ```powershell
   Copy-Item .\Platform.example.psd1 .\Platform.<environment>.psd1
   ```

   | Setting | Meaning |
   |---|---|
   | `TenantId` | Tenant of the subscriptions (empty = tenant of the current `az login`) |
   | `ManagementSubscriptionId` / `ConnectivitySubscriptionId` | Platform subscriptions |
   | `Locations` | Regions, primary first. One hub per region |
   | `NameToken` | `<token>` in resource names (`alz` = ALZ default names) |
   | `NetworkType` | `hubNetworking`, `vwanConnectivity` or `none` |
   | `ResourceLockKind` | `None`, `CanNotDelete` or `ReadOnly` on every resource |
   | `Tags` | Tags on every resource |
   | `Management` | Log retention, daily cap, solutions, Automation account |
   | `Connectivity` | Address prefixes (one per location) and feature switches |

2. Sign in and preview (what-if is the default mode):

   ```powershell
   az login --tenant <tenant-id>
   .\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1
   ```

3. Deploy, both subscriptions or one at a time:

   ```powershell
   .\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1 -Mode Deploy
   .\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1 -Mode Deploy -Component Management
   ```

   Connectivity takes 30-60 minutes with Azure Firewall, longer with gateways.

| `-Mode` | Does |
|---|---|
| `WhatIf` (default) | `az deployment sub what-if` |
| `Validate` | `az deployment sub validate` |
| `Deploy` | `az deployment sub create`, then writes the governance inputs |
| `Outputs` | Only (re)writes the governance inputs from what is deployed |

## Governance inputs

After `-Mode Deploy` (or `-Mode Outputs`), `out\governance-inputs.<environment>.json`
holds the IDs of what was deployed. Feed them to the ALZ policy assignments of the
governance repository:

| Value | ALZ policy assignment (parameter) | Scope |
|---|---|---|
| `logAnalyticsWorkspaceResourceId` | `Deploy-MDFC-Config-*`, `Deploy-AzActivity-Log`, `Deploy-Diag-LogsCat`, `Deploy-AzSqlDb-Auditing` (`logAnalytics` / `logAnalyticsWorkspaceResourceId`) | Intermediate root |
| `dataCollectionRuleVMInsightsResourceId` + `userAssignedIdentityResourceId` | `Deploy-VM-Monitoring`, `Deploy-VMSS-Monitoring`, `Deploy-vmHybr-Monitoring` (`dcrResourceId`, `userAssignedIdentityResourceId`) | Platform, Landing zones |
| `dataCollectionRuleChangeTrackingResourceId` + `userAssignedIdentityResourceId` | `Deploy-VM-ChangeTrack`, `Deploy-VMSS-ChangeTrack`, `Deploy-vmArc-ChangeTrack` | Platform, Landing zones |
| `dataCollectionRuleMDFCSQLResourceId` + `userAssignedIdentityResourceId` | `Deploy-MDFC-DefSQL-AMA` | Platform, Landing zones |
| `ddosProtectionPlanResourceId` | `Enable-DDoS-VNET` (`ddosPlan`). Without a plan, set this assignment to `DoNotEnforce` | Connectivity, Landing zones |
| `privateDnsZonesResourceGroupId` | `Deploy-Private-DNS-Zones` (one `azure*PrivateDnsZoneId` per zone, in this resource group) | Corp |
| `hubs[].hubResourceId`, `hubs[].azureFirewallPrivateIp` | Spoke peering / vWAN connection and default route next hop | Landing zone subscriptions |

Recommended order:

1. Governance repository: management groups, policies, subscription placement
2. **Management** (this folder)
3. Governance repository: update the assignments above with the Management IDs
4. **Connectivity** (this folder)
5. Governance repository: DDoS and private DNS zone assignments

## Upgrading the accelerator templates

The templates in `upstream\alz-bicep-accelerator` are a pinned, unmodified copy
(`VENDORED.md` has the tag and commit). Never edit them: change
`params\*.bicepparam` instead.

```powershell
.\Sync-Upstream.ps1 -Ref v2.5.0    # then update the $Ref default in the script
git diff -- upstream                # review: parameter renames break the .bicepparam files
.\Deploy-Platform.ps1 -ConfigFile .\Platform.<environment>.psd1   # what-if before deploying
```

## Known upstream behaviors (v2.4.0)

- **Basic firewall + DNS resolver**: the hub template sets the hub VNet DNS to the
  firewall IP but only enables the DNS proxy on Standard / Premium.
  `Deploy-Platform.ps1` refuses this combination.
- **VNet peering**: our parameters make hub *i* peer only with hubs *j > i*; the
  template creates both directions, so every pair is peered once.
- **Resource names** used to collect the governance inputs are repeated in
  `Deploy-Platform.ps1`: keep them in sync with the `.bicepparam` files.
