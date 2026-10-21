// ==============================================================
// Connectivity subscription - hub & spoke networking
//
// Template : ALZ Bicep Accelerator templates/networking/hubnetworking (vendored)
// Deploys  : one hub per location in ALZ_LOCATIONS (primary first):
//            rg-<token>-conn-<loc>  : hub VNet, Azure Firewall + policy, Bastion,
//                                     VPN / ExpressRoute gateways, route tables, DDoS plan
//            rg-<token>-dns-<loc>   : Private Link private DNS zones
//            rg-<token>-dnspr-<loc> : DNS Private Resolver
//
// Each hub gets its subnets carved out of the first /24 of its address
// space (see varSubnets), so a hub prefix must be /24 or larger (/22
// recommended, leaves room for more subnets).
//
// Expensive or environment-specific features default to OFF here:
// enable them explicitly in Platform.<env>.psd1 (Connectivity section).
//
// Environment-specific values come from Platform.<env>.psd1, passed by
// Deploy-Platform.ps1 as ALZ_* environment variables.
// ==============================================================
using '../upstream/alz-bicep-accelerator/templates/networking/hubnetworking/main.bicep'

var locations = json(readEnvironmentVariable('ALZ_LOCATIONS'))
var token = readEnvironmentVariable('ALZ_NAME_TOKEN', 'alz')
var cfg = any(json(readEnvironmentVariable('ALZ_CONNECTIVITY', '{}')))
var subscriptionId = readEnvironmentVariable('ALZ_CONNECTIVITY_SUBSCRIPTION_ID', '')

var hubAddressPrefixes = cfg.?HubAddressPrefixes ?? map(range(0, length(locations)), i => '10.${i}.0.0/22')
var hubNames = map(locations, loc => 'vnet-${token}-${loc}')
var hubIds = map(
  range(0, length(locations)),
  i => '/subscriptions/${subscriptionId}/resourceGroups/rg-${token}-conn-${locations[i]}/providers/Microsoft.Network/virtualNetworks/${hubNames[i]}'
)

// Same layout as the accelerator reference (x.x.0.0/24 of each hub)
var varSubnets = map(hubAddressPrefixes, prefix => [
  { name: 'AzureFirewallSubnet', addressPrefix: cidrSubnet(prefix, 26, 0) }
  { name: 'AzureBastionSubnet', addressPrefix: cidrSubnet(prefix, 26, 1) }
  { name: 'GatewaySubnet', addressPrefix: cidrSubnet(prefix, 27, 4) }
  { name: 'DNSPrivateResolverInboundSubnet', addressPrefix: cidrSubnet(prefix, 28, 10), delegation: 'Microsoft.Network/dnsResolvers' }
  { name: 'DNSPrivateResolverOutboundSubnet', addressPrefix: cidrSubnet(prefix, 28, 11), delegation: 'Microsoft.Network/dnsResolvers' }
  { name: 'AzureFirewallManagementSubnet', addressPrefix: cidrSubnet(prefix, 26, 3) }
])

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
param parHubNetworkingResourceGroupNamePrefix = 'rg-${token}-conn'
param parDnsResourceGroupNamePrefix = 'rg-${token}-dns'
param parDnsPrivateResolverResourceGroupNamePrefix = 'rg-${token}-dnspr'

// Hubs
param hubNetworks = map(range(0, length(locations)), i => {
  name: hubNames[i]
  location: locations[i]
  addressPrefixes: [
    hubAddressPrefixes[i]
  ]
  subnets: varSubnets[i]
  dnsServers: []

  // Full mesh between hubs: hub i peers with every hub j > i, the
  // template creates both directions of each peering.
  deployPeering: length(locations) > i + 1
  peeringSettings: map(filter(range(0, length(locations)), j => j > i), j => {
    remoteVirtualNetworkName: hubNames[j]
    allowForwardedTraffic: true
    allowGatewayTransit: false
    allowVirtualNetworkAccess: true
    useRemoteGateways: false
  })

  azureFirewallSettings: {
    deployAzureFirewall: cfg.?DeployAzureFirewall ?? true
    azureFirewallName: 'afw-${token}-${locations[i]}'
    azureSkuTier: cfg.?AzureFirewallSku ?? 'Standard'
    publicIPAddressObject: {
      name: 'pip-afw-${token}-${locations[i]}'
    }
    managementIPAddressObject: {
      name: 'pip-afw-mgmt-${token}-${locations[i]}'
    }
  }

  bastionHostSettings: {
    deployBastion: cfg.?DeployBastion ?? false
    bastionHostSettingsName: 'bas-${token}-${locations[i]}'
    skuName: cfg.?BastionSku ?? 'Standard'
  }

  vpnGatewaySettings: {
    deployVpnGateway: cfg.?DeployVpnGateway ?? false
    name: 'vgw-${token}-${locations[i]}'
    skuName: cfg.?VpnGatewaySku ?? 'VpnGw1AZ'
    vpnMode: cfg.?VpnGatewayMode ?? 'activeActiveBgp'
    vpnType: 'RouteBased'
    asn: cfg.?VpnGatewayAsn ?? 65515
  }

  expressRouteGatewaySettings: {
    deployExpressRouteGateway: cfg.?DeployExpressRouteGateway ?? false
    name: 'ergw-${token}-${locations[i]}'
  }

  privateDnsSettings: {
    deployPrivateDnsZones: cfg.?DeployPrivateDnsZones ?? true
    deployDnsPrivateResolver: cfg.?DeployDnsPrivateResolver ?? true
    privateDnsResolverName: 'dnspr-${token}-${locations[i]}'
    privateDnsZones: i == 0 ? [] : secondaryRegionPrivateDnsZones
    // Link the zones to the other hubs too, so every region resolves
    // every zone (needs the subscription ID to build the VNet IDs)
    virtualNetworkResourceIdsToLinkTo: empty(subscriptionId)
      ? []
      : map(filter(range(0, length(locations)), j => j != i), j => hubIds[j])
  }

  // One plan (primary region) covers the VNets of all regions
  ddosProtectionPlanSettings: {
    deployDdosProtectionPlan: i == 0 && (cfg.?DeployDdosProtectionPlan ?? false)
    name: 'ddos-${token}-${locations[i]}'
  }
})
