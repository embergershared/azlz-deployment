// ==============================================================
// Connectivity subscription - Virtual WAN
//
// Template : ALZ Bicep Accelerator templates/networking/virtualwan (vendored)
// Deploys  : one Virtual WAN (primary location) and one virtual hub per
//            location in ALZ_LOCATIONS (primary first):
//            rg-<token>-conn-<loc>  : vWAN, virtual hub, secured hub firewall,
//                                     gateways, "sidecar" VNet (Bastion, DNS resolver)
//            rg-<token>-dns-<loc>   : Private Link private DNS zones
//            rg-<token>-dnspr-<loc> : DNS Private Resolver
//
// Expensive or environment-specific features default to OFF here:
// enable them explicitly in Platform.<env>.psd1 (Connectivity section).
//
// Environment-specific values come from Platform.<env>.psd1, passed by
// Deploy-Platform.ps1 as ALZ_* environment variables.
// ==============================================================
using '../upstream/alz-bicep-accelerator/templates/networking/virtualwan/main.bicep'

var locations = json(readEnvironmentVariable('ALZ_LOCATIONS'))
var token = readEnvironmentVariable('ALZ_NAME_TOKEN', 'alz')
var cfg = any(json(readEnvironmentVariable('ALZ_CONNECTIVITY', '{}')))

// Virtual hub: /23 minimum (/22 leaves room for growth).
// Sidecar VNet: DNS resolver /28s + Bastion /26 are carved out of it.
var hubAddressPrefixes = cfg.?HubAddressPrefixes ?? map(range(0, length(locations)), i => '10.${i}.0.0/22')
var sidecarAddressPrefixes = cfg.?SidecarAddressPrefixes ?? map(range(0, length(locations)), i => '10.${i}.4.0/22')

// Regional Private Link zones deployed in the secondary hubs. The primary
// hub deploys the full default list (including its own regional zones).
var secondaryRegionPrivateDnsZones = [
  'privatelink.{regionName}.azurecontainerapps.io'
  'privatelink.{regionName}.kusto.windows.net'
  'privatelink.{regionName}.azmk8s.io'
  'privatelink.{regionName}.prometheus.monitor.azure.com'
  'privatelink.{regionCode}.backup.windowsazure.com'
]

// General
param parLocations = locations
param parTags = json(readEnvironmentVariable('ALZ_TAGS', '{}'))
param parEnableTelemetry = bool(readEnvironmentVariable('ALZ_ENABLE_TELEMETRY', 'true'))
param parGlobalResourceLock = {
  name: 'GlobalResourceLock'
  kind: readEnvironmentVariable('ALZ_LOCK_KIND', 'None')
  notes: 'Created by the azlz-deployment wrapper (ALZ Bicep Accelerator).'
}

// Resource groups: <prefix>-<location>
param parVirtualWanResourceGroupNamePrefix = 'rg-${token}-conn'
param parDnsResourceGroupNamePrefix = 'rg-${token}-dns'
param parDnsPrivateResolverResourceGroupNamePrefix = 'rg-${token}-dnspr'

// Virtual WAN
param vwan = {
  name: 'vwan-${token}-${locations[0]}'
  location: locations[0]
  type: 'Standard'
  allowBranchToBranchTraffic: true
}

// Virtual hubs
param vwanHubs = map(range(0, length(locations)), i => {
  hubName: 'vhub-${token}-${locations[i]}'
  location: locations[i]
  addressPrefix: hubAddressPrefixes[i]
  allowBranchToBranchTraffic: true
  preferredRoutingGateway: cfg.?PreferredRoutingGateway ?? 'ExpressRoute'

  azureFirewallSettings: {
    deployAzureFirewall: cfg.?DeployAzureFirewall ?? true
    name: 'afw-${token}-${locations[i]}'
    azureSkuTier: cfg.?AzureFirewallSku ?? 'Standard'
  }

  expressRouteGatewaySettings: {
    deployExpressRouteGateway: cfg.?DeployExpressRouteGateway ?? false
    name: 'ergw-${token}-${locations[i]}'
    minScaleUnits: 1
    maxScaleUnits: 1
    allowNonVirtualWanTraffic: false
  }

  s2sVpnGatewaySettings: {
    deployS2sVpnGateway: cfg.?DeployVpnGateway ?? false
    name: 's2s-${token}-${locations[i]}'
    scaleUnit: 1
  }

  p2sVpnGatewaySettings: {
    deployP2sVpnGateway: false
    name: 'p2s-${token}-${locations[i]}'
    scaleUnit: 1
    vpnServerConfiguration: {
      vpnAuthenticationTypes: [
        'AAD'
      ]
    }
    vpnClientAddressPool: {
      addressPrefixes: [
        '172.16.${i}.0/24'
      ]
    }
  }

  // One plan (primary region) covers the VNets of all regions
  ddosProtectionPlanSettings: {
    deployDdosProtectionPlan: i == 0 && (cfg.?DeployDdosProtectionPlan ?? false)
    name: 'ddos-${token}-${locations[i]}'
  }

  dnsSettings: {
    deployPrivateDnsZones: cfg.?DeployPrivateDnsZones ?? true
    deployDnsPrivateResolver: cfg.?DeployDnsPrivateResolver ?? true
    privateDnsResolverName: 'dnspr-${token}-${locations[i]}'
    privateDnsZones: i == 0 ? [] : secondaryRegionPrivateDnsZones
  }

  bastionSettings: {
    deployBastion: cfg.?DeployBastion ?? false
    name: 'bas-${token}-${locations[i]}'
    sku: cfg.?BastionSku ?? 'Standard'
  }

  sideCarVirtualNetwork: {
    name: 'vnet-sidecar-${token}-${locations[i]}'
    sidecarVirtualNetworkEnabled: true
    addressPrefixes: [
      sidecarAddressPrefixes[i]
    ]
  }
})
