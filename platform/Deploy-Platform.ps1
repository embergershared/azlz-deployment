# ==============================================================
# Azure Landing Zone - Platform subscriptions deployment
#
# Deploys the ALZ Bicep Accelerator templates (vendored in
# .\upstream, see Sync-Upstream.ps1) to the platform subscriptions:
#
#   Management   : templates/core/logging             <- params\management.bicepparam
#   Connectivity : templates/networking/hubnetworking <- params\connectivity-hubnetworking.bicepparam
#               or templates/networking/virtualwan    <- params\connectivity-virtualwan.bicepparam
#
# Management groups, policies and assignments are NOT deployed here
# (separate governance repository). After a deployment, the resource
# IDs that the ALZ policy assignments need (Log Analytics workspace,
# DCRs, AMA identity, DDoS plan, private DNS zones resource group...)
# are written to .\out\governance-inputs.<environment>.json.
#
# Each environment lives in its own config file - see Platform.example.psd1.
# Values reach the .bicepparam files as ALZ_* environment variables.
#
# Modes:
#   WhatIf   (default) az deployment sub what-if
#   Validate           az deployment sub validate
#   Deploy             az deployment sub create
#   Outputs            only (re)write the governance inputs file
#
# Usage:
#   .\Deploy-Platform.ps1 -ConfigFile .\Platform.contoso.psd1
#   .\Deploy-Platform.ps1 -ConfigFile .\Platform.contoso.psd1 -Mode Deploy
#   .\Deploy-Platform.ps1 -ConfigFile .\Platform.contoso.psd1 -Mode Deploy -Component Management
# ==============================================================
#Requires -Version 7.0

param(
    # Environment config file (.psd1)
    [Parameter(Mandatory)]
    [string] $ConfigFile,

    [ValidateSet("WhatIf", "Validate", "Deploy", "Outputs")]
    [string] $Mode = "WhatIf",

    # Platform subscription(s) to deploy, in this order
    [ValidateSet("Management", "Connectivity")]
    [string[]] $Component = @("Management", "Connectivity")
)

$ErrorActionPreference = "Stop"

$NetworkTemplates = @{
    hubNetworking    = "connectivity-hubnetworking.bicepparam"
    vwanConnectivity = "connectivity-virtualwan.bicepparam"
}

# --------------------------------------------------------------
# LOAD AND CHECK CONFIG
# --------------------------------------------------------------
$Config      = Import-PowerShellDataFile -Path $ConfigFile
$Environment = [IO.Path]::GetFileNameWithoutExtension($ConfigFile) -replace '^Platform\.', ''

$Locations    = @($Config.Locations | Where-Object { $_ })
$NameToken    = if ($Config.NameToken) { $Config.NameToken } else { "alz" }
$NetworkType  = if ($Config.NetworkType) { $Config.NetworkType } else { "hubNetworking" }
$Management   = if ($Config.Management) { $Config.Management } else { @{} }
$Connectivity = if ($Config.Connectivity) { $Config.Connectivity } else { @{} }

if (-not $Locations)                         { throw "Locations is empty in $ConfigFile" }
if (-not $Config.ManagementSubscriptionId)   { throw "ManagementSubscriptionId is missing in $ConfigFile" }
if (-not $Config.ConnectivitySubscriptionId) { throw "ConnectivitySubscriptionId is missing in $ConfigFile" }
if ($NetworkType -notin @($NetworkTemplates.Keys) + "none") {
    throw "NetworkType '$NetworkType' is not one of: $($NetworkTemplates.Keys -join ', '), none"
}

foreach ($Key in "HubAddressPrefixes", "SidecarAddressPrefixes") {
    if ($Connectivity.ContainsKey($Key) -and @($Connectivity[$Key]).Count -ne $Locations.Count) {
        throw "Connectivity.$Key needs one entry per location ($($Locations.Count))"
    }
}

# Upstream hub template points the hub VNet DNS to the firewall when the
# firewall + DNS resolver + private DNS zones are deployed, but only
# enables the firewall DNS proxy for Standard / Premium.
if ($NetworkType -eq "hubNetworking" -and
    $Connectivity.AzureFirewallSku -eq "Basic" -and
    $Connectivity.DeployAzureFirewall -ne $false -and
    $Connectivity.DeployDnsPrivateResolver -ne $false -and
    $Connectivity.DeployPrivateDnsZones -ne $false) {
    throw "AzureFirewallSku 'Basic' has no DNS proxy: set DeployDnsPrivateResolver = `$false (or use Standard) to keep name resolution working"
}

Write-Host "Config file   : $((Resolve-Path $ConfigFile).Path)" -ForegroundColor Cyan
Write-Host "Environment   : $Environment"
Write-Host "Mode          : $Mode"
Write-Host "Locations     : $($Locations -join ', ')"
Write-Host "Network type  : $NetworkType"

# --------------------------------------------------------------
# AZ CLI CONTEXT
# --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required: https://aka.ms/azcli"
}
$Account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $Account) {
    throw "Not signed in: run 'az login$(if ($Config.TenantId) { " --tenant $($Config.TenantId)" })'"
}
if ($Config.TenantId -and $Account.tenantId -ne $Config.TenantId) {
    throw "Signed in to tenant $($Account.tenantId), config expects $($Config.TenantId): run 'az login --tenant $($Config.TenantId)'"
}
Write-Host "Signed in as  : $($Account.user.name) (tenant $($Account.tenantId))"

# --------------------------------------------------------------
# VALUES FOR THE .bicepparam FILES (readEnvironmentVariable)
# --------------------------------------------------------------
$env:ALZ_LOCATIONS                    = ConvertTo-Json -InputObject $Locations -Compress
$env:ALZ_NAME_TOKEN                   = $NameToken
$env:ALZ_TAGS                         = ConvertTo-Json -InputObject ($Config.Tags ?? @{}) -Compress -Depth 5
$env:ALZ_LOCK_KIND                    = if ($Config.ResourceLockKind) { $Config.ResourceLockKind } else { "None" }
$env:ALZ_ENABLE_TELEMETRY             = if ($Config.EnableTelemetry -eq $false) { "false" } else { "true" }
$env:ALZ_MANAGEMENT                   = ConvertTo-Json -InputObject $Management -Compress -Depth 5
$env:ALZ_CONNECTIVITY                 = ConvertTo-Json -InputObject $Connectivity -Compress -Depth 5
$env:ALZ_CONNECTIVITY_SUBSCRIPTION_ID = $Config.ConnectivitySubscriptionId

# --------------------------------------------------------------
# DEPLOYMENTS
# --------------------------------------------------------------
$Deployments = foreach ($Name in $Component) {
    switch ($Name) {
        "Management" {
            @{ Name = "Management"; SubscriptionId = $Config.ManagementSubscriptionId; ParamFile = "management.bicepparam" }
        }
        "Connectivity" {
            if ($NetworkType -eq "none") {
                Write-Host "Connectivity skipped (NetworkType = none)" -ForegroundColor Yellow
            }
            else {
                @{ Name = "Connectivity"; SubscriptionId = $Config.ConnectivitySubscriptionId; ParamFile = $NetworkTemplates[$NetworkType] }
            }
        }
    }
}

if ($Mode -ne "Outputs") {
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    foreach ($Deployment in $Deployments) {
        $ParamPath      = Join-Path $PSScriptRoot "params/$($Deployment.ParamFile)"
        $DeploymentName = "alz-$($Deployment.Name.ToLower())-$Timestamp"
        $Verb           = @{ WhatIf = "what-if"; Validate = "validate"; Deploy = "create" }[$Mode]

        Write-Host ""
        Write-Host "==> $($Deployment.Name) : az deployment sub $Verb ($($Deployment.ParamFile))" -ForegroundColor Cyan
        Write-Host "    Subscription : $($Deployment.SubscriptionId)"
        Write-Host "    Deployment   : $DeploymentName ($($Locations[0]))"

        $Arguments = @(
            "deployment", "sub", $Verb
            "--subscription", $Deployment.SubscriptionId
            "--name", $DeploymentName
            "--location", $Locations[0]
            "--parameters", $ParamPath
        )
        # what-if prints its own change report
        if ($Mode -ne "WhatIf") { $Arguments += "--output", "table" }

        az @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$($Deployment.Name) $Mode failed" }

        Write-Host "    $Mode succeeded" -ForegroundColor Green
    }

    if ($Mode -ne "Deploy") { return }
}

# --------------------------------------------------------------
# GOVERNANCE INPUTS
# IDs the ALZ policy assignments of the governance repository need.
# Names follow the conventions of the params\*.bicepparam files.
# --------------------------------------------------------------
function Get-ResourceIds([string] $SubscriptionId) {
    $Ids = az resource list --subscription $SubscriptionId --query "[].id" --output tsv
    if ($LASTEXITCODE -ne 0) { throw "az resource list failed on $SubscriptionId" }
    return @($Ids | Where-Object { $_ })
}

# -like is case-insensitive: ARM may return resource group names in upper case
function Find-Id([string[]] $Ids, [string] $ResourceGroup, [string] $Type, [string] $Name) {
    return $Ids | Where-Object { $_ -like "*/resourceGroups/$ResourceGroup/providers/$Type/$Name" } | Select-Object -First 1
}

$Primary = $Locations[0]
$Inputs  = [ordered]@{
    environment                = $Environment
    generatedAt                = (Get-Date).ToUniversalTime().ToString("o")
    managementSubscriptionId   = $Config.ManagementSubscriptionId
    connectivitySubscriptionId = $Config.ConnectivitySubscriptionId
}

$Ids = Get-ResourceIds $Config.ManagementSubscriptionId
$Rg  = "rg-$NameToken-logging-$Primary"
$Inputs.logAnalyticsWorkspaceResourceId            = Find-Id $Ids $Rg "Microsoft.OperationalInsights/workspaces" "law-$NameToken-$Primary"
$Inputs.userAssignedIdentityResourceId             = Find-Id $Ids $Rg "Microsoft.ManagedIdentity/userAssignedIdentities" "mi-$NameToken-$Primary"
$Inputs.dataCollectionRuleVMInsightsResourceId     = Find-Id $Ids $Rg "Microsoft.Insights/dataCollectionRules" "dcr-vmi-$NameToken-$Primary"
$Inputs.dataCollectionRuleChangeTrackingResourceId = Find-Id $Ids $Rg "Microsoft.Insights/dataCollectionRules" "dcr-ct-$NameToken-$Primary"
$Inputs.dataCollectionRuleMDFCSQLResourceId        = Find-Id $Ids $Rg "Microsoft.Insights/dataCollectionRules" "dcr-mdfcsql-$NameToken-$Primary"
$Inputs.automationAccountResourceId                = Find-Id $Ids $Rg "Microsoft.Automation/automationAccounts" "aa-$NameToken-$Primary"

if ($NetworkType -ne "none") {
    $Ids = Get-ResourceIds $Config.ConnectivitySubscriptionId
    $Inputs.ddosProtectionPlanResourceId = Find-Id $Ids "rg-$NameToken-conn-$Primary" "Microsoft.Network/ddosProtectionPlans" "ddos-$NameToken-$Primary"

    # Resource group holding the Private Link zones (ALZ "Deploy-Private-DNS-Zones" assignment)
    $DnsRg = "rg-$NameToken-dns-$Primary"
    $Inputs.privateDnsZonesResourceGroupId = if ($Ids | Where-Object { $_ -like "*/resourceGroups/$DnsRg/providers/Microsoft.Network/privateDnsZones/*" }) {
        "/subscriptions/$($Config.ConnectivitySubscriptionId)/resourceGroups/$DnsRg"
    }

    $Inputs.hubs = @(foreach ($Location in $Locations) {
        $ConnRg = "rg-$NameToken-conn-$Location"
        if ($NetworkType -eq "hubNetworking") {
            $Hub        = Find-Id $Ids $ConnRg "Microsoft.Network/virtualNetworks" "vnet-$NameToken-$Location"
            $IpProperty = "properties.ipConfigurations[0].properties.privateIPAddress"
        }
        else {
            $Hub        = Find-Id $Ids $ConnRg "Microsoft.Network/virtualHubs" "vhub-$NameToken-$Location"
            $IpProperty = "properties.hubIPAddresses.privateIPAddress"
        }
        $Firewall = Find-Id $Ids $ConnRg "Microsoft.Network/azureFirewalls" "afw-$NameToken-$Location"

        [ordered]@{
            location                = $Location
            hubResourceId           = $Hub
            azureFirewallResourceId = $Firewall
            # Next hop of the spokes' default route
            azureFirewallPrivateIp  = if ($Firewall) { az resource show --ids $Firewall --query $IpProperty --output tsv }
        }
    })
}

$Missing = @($Inputs.Keys | Where-Object { $_ -like "*ResourceId" -and -not $Inputs[$_] })
if ($Missing) {
    Write-Host ""
    Write-Host "Not found (not deployed / disabled): $($Missing -join ', ')" -ForegroundColor Yellow
}

$OutDir  = Join-Path $PSScriptRoot "out"
$OutFile = Join-Path $OutDir "governance-inputs.$Environment.json"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$Inputs | ConvertTo-Json -Depth 5 | Set-Content -Path $OutFile -Encoding utf8

Write-Host ""
Write-Host "Governance inputs written to $OutFile" -ForegroundColor Green
Write-Host "Feed them to the ALZ policy assignments of the governance repository."
