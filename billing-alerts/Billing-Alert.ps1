# ==============================================================
# Azure Monthly Billing Budget
#
# Creates / updates one monthly Cost budget per subscription, with
# email alerts at percentages of the budget amount (default 70, 80,
# 90 and 100%).
#
# Budget Name = <BudgetNamePrefix>-<Azure Subscription Name>
#   e.g. Monthly-Cost-Budget-Contoso-Hub-Connectivity
#   (a subscription entry in the config can set its own BudgetName)
#
# Budgets created by earlier versions of this script were named after
# the subscription only. They are detected and reported; add
# -RemoveLegacyBudgets to delete them once the new budget is created
# (otherwise recipients get every alert twice).
#
# Each environment (tenant, subscriptions, recipients) lives in its
# own config file - see Billing-Alert.example.psd1.
#
# Usage:
#   .\Billing-Alert.ps1 -ConfigFile .\Billing-Alert.contoso.psd1
#
#   # Override config values from the command line:
#   .\Billing-Alert.ps1 -ConfigFile .\Billing-Alert.contoso.psd1 -EmailAddresses "me@contoso.com"
#
#   # No config file - everything on the command line:
#   .\Billing-Alert.ps1 -TenantId "<tenant-id>" `
#       -EmailAddresses "finops@contoso.com", "lead@contoso.com" `
#       -Subscriptions @("<subscription-id>", 250), @("<subscription-id>")
# ==============================================================

param(
    # Environment config file (.psd1). Command-line parameters below
    # override the values it contains.
    [string] $ConfigFile,

    # Microsoft Entra tenant of the subscriptions
    # (default: tenant of the current Azure context)
    [string] $TenantId,

    # Each entry is a (SubscriptionId, BudgetAmount) tuple:
    #   @("<subscription-id>", 250)  -> $250 / month
    #   @("<subscription-id>")       -> default amount
    #   "<subscription-id>"          -> default amount
    [object[]] $Subscriptions,

    # Recipients of the budget alert emails
    [string[]] $EmailAddresses,

    # Used when a subscription has no budget amount
    [decimal] $DefaultBudgetAmount = 100,

    # Alert thresholds, in percent of the budget amount
    [int[]] $ThresholdPercents = @(70, 80, 90, 100),

    # Budget name = <prefix>-<subscription name>
    [string] $BudgetNamePrefix = "Monthly-Cost-Budget",

    # Delete budgets named after the subscription only (naming used by
    # earlier versions of this script) after the new budget is created
    [switch] $RemoveLegacyBudgets
)

$ErrorActionPreference = "Stop"
$ApiVersion            = "2023-05-01"

# --------------------------------------------------------------
# LOAD CONFIG FILE (command-line parameters take precedence)
# --------------------------------------------------------------
if ($ConfigFile) {
    $Config = Import-PowerShellDataFile -Path $ConfigFile

    foreach ($Key in "TenantId", "Subscriptions", "EmailAddresses", "DefaultBudgetAmount", "ThresholdPercents", "BudgetNamePrefix") {
        if ($Config.ContainsKey($Key) -and -not $PSBoundParameters.ContainsKey($Key)) {
            Set-Variable -Name $Key -Value $Config[$Key]
        }
    }
    Write-Host "Config file   : $((Resolve-Path $ConfigFile).Path)" -ForegroundColor Cyan
}

# --------------------------------------------------------------
# VALIDATE INPUT
# --------------------------------------------------------------
if (-not $Subscriptions) {
    throw "No subscriptions given. Use -ConfigFile or -Subscriptions (see the usage at the top of the script)."
}

$EmailAddresses = @($EmailAddresses | Where-Object { $_ } | ForEach-Object { $_.Trim() })
if (-not $EmailAddresses) {
    throw "No alert recipients given. Use -ConfigFile or -EmailAddresses."
}
$BadEmails = @($EmailAddresses | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
if ($BadEmails) {
    throw "Invalid email address(es): $($BadEmails -join ', ')"
}

if (-not $ThresholdPercents -or @($ThresholdPercents | Where-Object { $_ -le 0 -or $_ -gt 1000 })) {
    throw "Threshold percents must be between 1 and 1000 (got $($ThresholdPercents -join ', '))."
}
if ($ThresholdPercents.Count -gt 5) {
    throw "Azure budgets support at most 5 notifications (got $($ThresholdPercents.Count) thresholds)."
}

# --------------------------------------------------------------
# NORMALIZE INPUT -> (SubscriptionId, BudgetAmount)
# --------------------------------------------------------------
$Targets = @()
for ($i = 0; $i -lt $Subscriptions.Count; $i++) {
    $Entry = $Subscriptions[$i]

    # Unwrap extra nesting such as @(,@("id", 250))
    while ($Entry -is [array] -and $Entry.Count -eq 1 -and $Entry[0] -is [array]) {
        $Entry = $Entry[0]
    }

    $CustomBudgetName = $null

    if ($Entry -is [System.Collections.IDictionary]) {
        # Config file form: @{ Id = "<subscription-id>"; Amount = 250; Name = "..."; BudgetName = "..." }
        $Id     = [string]$Entry.Id
        $Amount = if ($null -ne $Entry.Amount -and "$($Entry.Amount)" -ne "") { $Entry.Amount } else { $DefaultBudgetAmount }
        $CustomBudgetName = $Entry.BudgetName
    }
    elseif ($Entry -is [array]) {
        $Id     = [string]$Entry[0]
        $Amount = if ($Entry.Count -gt 1 -and $null -ne $Entry[1] -and "$($Entry[1])" -ne "") { $Entry[1] } else { $DefaultBudgetAmount }
    }
    else {
        # A single tuple passed as @("id", 250) is flattened by PowerShell
        # into "id", 250 - pair the id with the number that follows it
        $Id     = [string]$Entry
        $Amount = $DefaultBudgetAmount
        if ($i + 1 -lt $Subscriptions.Count -and $Subscriptions[$i + 1] -is [ValueType]) {
            $Amount = $Subscriptions[$i + 1]
            $i++
        }
    }

    $Id = $Id.Trim().ToLower()
    if ($Id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw "Invalid subscription id '$Id'."
    }

    $Amount = [decimal]$Amount
    if ($Amount -le 0) {
        throw "Budget amount for subscription $Id must be greater than 0 (got $Amount)."
    }

    $Targets += [pscustomobject]@{ SubscriptionId = $Id; BudgetAmount = $Amount; BudgetName = $CustomBudgetName }
}

# --------------------------------------------------------------
# CHECK FOR DUPLICATE SUBSCRIPTIONS
# --------------------------------------------------------------
# Same id with different amounts -> stop; same id and amount -> keep one
$Duplicates = $Targets | Group-Object SubscriptionId | Where-Object Count -gt 1

foreach ($Dup in $Duplicates) {
    $Amounts = @($Dup.Group.BudgetAmount | Sort-Object -Unique)
    if ($Amounts.Count -gt 1) {
        throw "Subscription $($Dup.Name) is listed $($Dup.Count) times with different budget amounts ($($Amounts -join ', ')). Keep only one entry."
    }
    Write-Warning "Subscription $($Dup.Name) is listed $($Dup.Count) times - processing it once."
}

if ($Duplicates) {
    # Keep the first occurrence, in the original order
    $Seen    = @{}
    $Targets = @($Targets | Where-Object { -not $Seen.ContainsKey($_.SubscriptionId) -and ($Seen[$_.SubscriptionId] = $true) })
}

# --------------------------------------------------------------
# CHECK / INSTALL MODULES
# --------------------------------------------------------------
$Modules = @("Az.Accounts", "Az.Resources")

foreach ($Module in $Modules) {
    if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Host "Installing $Module..." -ForegroundColor Yellow
        Install-Module -Name $Module -Scope CurrentUser -Repository PSGallery -Force
    }
    Import-Module $Module
}

# --------------------------------------------------------------
# LOGIN TO AZURE (target tenant)
# --------------------------------------------------------------
Write-Host ""
Write-Host "Connecting to Azure..." -ForegroundColor Cyan

$Context = Get-AzContext
if (-not $Context -or ($TenantId -and $Context.Tenant.Id -ne $TenantId)) {
    if ($TenantId) {
        Connect-AzAccount -TenantId $TenantId | Out-Null
    }
    else {
        Connect-AzAccount | Out-Null
    }
    $Context = Get-AzContext
}
if (-not $TenantId) {
    $TenantId = $Context.Tenant.Id
}

Write-Host "Account       : $($Context.Account.Id)"
Write-Host "Tenant        : $TenantId"
Write-Host "Recipients    : $($EmailAddresses -join ', ')"
Write-Host "Subscriptions : $($Targets.Count)"

# --------------------------------------------------------------
# BUDGET DATES
# --------------------------------------------------------------
# Start date must be the first day of the month (midnight, UTC)
$Today     = Get-Date
$StartDate = (Get-Date -Year $Today.Year -Month $Today.Month -Day 1).ToString("yyyy-MM-01T00:00:00Z")

# Give the budget a long expiration date
$EndDate = "2035-12-31T00:00:00Z"

# --------------------------------------------------------------
# NOTIFICATIONS (one per threshold)
# --------------------------------------------------------------
$Notifications = [ordered]@{}
foreach ($Percent in $ThresholdPercents) {
    $Notifications["Actual_GreaterThanOrEqualTo_$($Percent)_Percent"] = @{
        enabled       = $true
        operator      = "GreaterThanOrEqualTo"
        threshold     = $Percent
        thresholdType = "Actual"
        contactEmails = $EmailAddresses
    }
}

# --------------------------------------------------------------
# BUDGET NAMES
# --------------------------------------------------------------
# Keep only characters valid in a budget name / URL path (letters,
# digits, - and _), collapse repeated dashes, max 63 characters
function ConvertTo-BudgetName([string] $Text) {
    $Name = ($Text -replace '[^A-Za-z0-9_-]', '-' -replace '-{2,}', '-').Trim('-')
    if ($Name.Length -gt 63) { $Name = $Name.Substring(0, 63).TrimEnd('-') }
    return $Name
}

# Name used by earlier versions of this script: subscription name only
function Get-LegacyBudgetName([string] $SubscriptionName) {
    $Name = ($SubscriptionName -replace '[^A-Za-z0-9_-]', '-').Trim('-')
    if ($Name.Length -gt 63) { $Name = $Name.Substring(0, 63).TrimEnd('-') }
    return $Name
}

# --------------------------------------------------------------
# PROCESS EACH SUBSCRIPTION
# --------------------------------------------------------------
$Summary = @()

foreach ($Target in $Targets) {

    $SubscriptionId = $Target.SubscriptionId
    $BudgetAmount   = $Target.BudgetAmount

    # ----------------------------------------------------------
    # SELECT SUBSCRIPTION
    # ----------------------------------------------------------
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -Tenant $TenantId | Out-Null
        $Subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -TenantId $TenantId
    }
    catch {
        Write-Warning "Cannot access subscription $SubscriptionId in tenant $TenantId : $($_.Exception.Message)"
        $Summary += [pscustomobject]@{ Subscription = $SubscriptionId; Budget = ""; Amount = $BudgetAmount; Status = "Skipped (no access)"; OldBudget = "" }
        continue
    }

    $SubscriptionName = $Subscription.Name

    Write-Host ""
    Write-Host "Subscription Name : $SubscriptionName" -ForegroundColor Green
    Write-Host "Subscription ID   : $SubscriptionId" -ForegroundColor Green

    # ----------------------------------------------------------
    # BUDGET CONFIGURATION
    # ----------------------------------------------------------
    # <prefix>-<subscription name>, unless the config sets a BudgetName
    if ($Target.BudgetName) {
        $BudgetName = ConvertTo-BudgetName $Target.BudgetName
    }
    elseif ($BudgetNamePrefix) {
        $BudgetName = ConvertTo-BudgetName "$BudgetNamePrefix-$SubscriptionName"
    }
    else {
        $BudgetName = ConvertTo-BudgetName $SubscriptionName
    }

    Write-Host ""
    Write-Host "Budget Name   : $BudgetName"
    Write-Host "Monthly Budget: `$$BudgetAmount"
    foreach ($Percent in $ThresholdPercents) {
        Write-Host ("{0,-4} Alert    : `${1}" -f "$Percent%", ($BudgetAmount * $Percent / 100))
    }

    # ----------------------------------------------------------
    # CREATE RESOURCE BODY
    # ----------------------------------------------------------
    $BudgetBody = @{
        properties = @{
            category      = "Cost"
            amount        = $BudgetAmount
            timeGrain     = "Monthly"
            timePeriod    = @{
                startDate = $StartDate
                endDate   = $EndDate
            }
            notifications = $Notifications
        }
    } | ConvertTo-Json -Depth 20

    $BudgetResourceId = "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$BudgetName"

    # ----------------------------------------------------------
    # CREATE / UPDATE BUDGET
    # ----------------------------------------------------------
    Write-Host ""
    Write-Host "Creating Azure Budget..." -ForegroundColor Cyan

    $PutResult = Invoke-AzRestMethod -Method PUT -Path "$($BudgetResourceId)?api-version=$ApiVersion" -Payload $BudgetBody

    if ($PutResult.StatusCode -notin 200, 201) {
        Write-Warning "Failed to create budget for '$SubscriptionName' (HTTP $($PutResult.StatusCode)):"
        Write-Warning $PutResult.Content
        $Summary += [pscustomobject]@{ Subscription = $SubscriptionName; Budget = $BudgetName; Amount = $BudgetAmount; Status = "FAILED ($($PutResult.StatusCode))"; OldBudget = "" }
        continue
    }

    # ----------------------------------------------------------
    # VERIFY BUDGET
    # ----------------------------------------------------------
    Write-Host "Verifying budget..." -ForegroundColor Cyan

    $Result       = Invoke-AzRestMethod -Method GET -Path "$($BudgetResourceId)?api-version=$ApiVersion"
    $BudgetResult = $Result.Content | ConvertFrom-Json

    if ($Result.StatusCode -ne 200) {
        Write-Warning "Budget created but could not be read back (HTTP $($Result.StatusCode))."
    }
    else {
        Write-Host "Budget Name   : $($BudgetResult.name)"
        Write-Host "Budget Amount : `$$($BudgetResult.properties.amount)"
    }

    # ----------------------------------------------------------
    # OLD-NAMED BUDGET (earlier versions of this script)
    # ----------------------------------------------------------
    $OldBudget       = ""
    $LegacyName      = Get-LegacyBudgetName $SubscriptionName
    $LegacyPath      = "/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$($LegacyName)?api-version=$ApiVersion"

    if ($LegacyName -and $LegacyName -ne $BudgetName) {
        $LegacyResult = Invoke-AzRestMethod -Method GET -Path $LegacyPath

        if ($LegacyResult.StatusCode -eq 200) {
            if ($RemoveLegacyBudgets) {
                $DeleteResult = Invoke-AzRestMethod -Method DELETE -Path $LegacyPath
                if ($DeleteResult.StatusCode -in 200, 204) {
                    Write-Host "Old budget '$LegacyName' deleted." -ForegroundColor Yellow
                    $OldBudget = "Deleted $LegacyName"
                }
                else {
                    Write-Warning "Could not delete old budget '$LegacyName' (HTTP $($DeleteResult.StatusCode)): $($DeleteResult.Content)"
                    $OldBudget = "Delete FAILED: $LegacyName"
                }
            }
            else {
                Write-Warning "Old budget '$LegacyName' still exists - its alerts duplicate '$BudgetName'. Rerun with -RemoveLegacyBudgets to delete it."
                $OldBudget = "Still exists: $LegacyName"
            }
        }
    }

    $Summary += [pscustomobject]@{ Subscription = $SubscriptionName; Budget = $BudgetName; Amount = $BudgetAmount; Status = "OK"; OldBudget = $OldBudget }
}

# --------------------------------------------------------------
# DISPLAY RESULT
# --------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "       AZURE BUDGETS SUMMARY"
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Tenant        : $TenantId"
Write-Host "Recipients    : $($EmailAddresses -join ', ')"
Write-Host ("Email alerts at: {0} of each monthly budget" -f (($ThresholdPercents | ForEach-Object { "$_%" }) -join ", "))
$Summary | Format-Table -AutoSize

Write-Host "Budget configuration completed." -ForegroundColor Green
