// ==============================================================
// Management subscription - logging & monitoring
//
// Template : ALZ Bicep Accelerator templates/core/logging (vendored)
// Deploys  : rg-<token>-logging-<primary location> with
//            - Log Analytics workspace (+ ChangeTracking solution)
//            - Data collection rules (VM Insights, Change Tracking, Defender for SQL)
//            - User-assigned identity for the Azure Monitor Agent
//            - Automation account (optional)
//
// Environment-specific values come from Platform.<env>.psd1, passed by
// Deploy-Platform.ps1 as ALZ_* environment variables.
// ==============================================================
using '../upstream/alz-bicep-accelerator/templates/core/logging/main.bicep'

var locations = json(readEnvironmentVariable('ALZ_LOCATIONS'))
var token = readEnvironmentVariable('ALZ_NAME_TOKEN', 'alz')
var cfg = any(json(readEnvironmentVariable('ALZ_MANAGEMENT', '{}')))
var primary = locations[0]

// General
param parLocations = locations
param parTags = json(readEnvironmentVariable('ALZ_TAGS', '{}'))
param parEnableTelemetry = bool(readEnvironmentVariable('ALZ_ENABLE_TELEMETRY', 'true'))
param parGlobalResourceLock = {
  name: 'GlobalResourceLock'
  kind: readEnvironmentVariable('ALZ_LOCK_KIND', 'None')
  notes: 'Created by the azlz-deployment wrapper (ALZ Bicep Accelerator).'
}

// Resource group
param parMgmtLoggingResourceGroup = 'rg-${token}-logging-${primary}'

// Automation account (only needed for legacy Update Management / runbooks)
param parDeployAutomationAccount = cfg.?DeployAutomationAccount ?? false
param parAutomationAccountName = 'aa-${token}-${primary}'
param parAutomationAccountLocation = primary
param parAutomationAccountUseManagedIdentity = true
param parAutomationAccountPublicNetworkAccess = true
param parAutomationAccountSku = 'Basic'

// Log Analytics workspace
param parLogAnalyticsWorkspaceName = 'law-${token}-${primary}'
param parLogAnalyticsWorkspaceLocation = primary
param parLogAnalyticsWorkspaceSku = 'PerGB2018'
param parLogAnalyticsWorkspaceLogRetentionInDays = cfg.?LogRetentionInDays ?? 365
param parLogAnalyticsWorkspaceDailyQuotaGb = cfg.?DailyQuotaGb
// 'SecurityInsights' onboards the workspace to Microsoft Sentinel (billed per GB)
param parLogAnalyticsWorkspaceSolutions = cfg.?Solutions ?? [
  'ChangeTracking'
]

// Azure Monitor Agent: identity + data collection rules
// (referenced by the ALZ VM / VMSS / Arc monitoring policy assignments)
param parUserAssignedIdentityName = 'mi-${token}-${primary}'
param parDataCollectionRuleVMInsightsName = 'dcr-vmi-${token}-${primary}'
param parDataCollectionRuleChangeTrackingName = 'dcr-ct-${token}-${primary}'
param parDataCollectionRuleMDFCSQLName = 'dcr-mdfcsql-${token}-${primary}'
