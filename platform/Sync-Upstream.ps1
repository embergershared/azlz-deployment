# ==============================================================
# Sync ALZ Bicep Accelerator templates (vendoring)
#
# Copies the Management (logging) and Connectivity (hub networking,
# virtual WAN) templates of https://github.com/Azure/alz-bicep-accelerator
# at a pinned release tag into .\upstream\alz-bicep-accelerator.
#
# The vendored files are committed: deployments are reproducible and
# an upgrade shows up as a reviewable git diff. Never edit them -
# customization belongs in .\params\*.bicepparam.
#
# Governance (management groups, policies, assignments) is NOT
# vendored: it is deployed from a separate repository.
#
# Usage:
#   .\Sync-Upstream.ps1                  # tag pinned below
#   .\Sync-Upstream.ps1 -Ref v2.5.0      # upgrade: review the diff, update $Ref default
# ==============================================================

param(
    # Release tag (or branch / commit) of the accelerator to vendor
    [string] $Ref = "v2.4.0",

    [string] $RepositoryUrl = "https://github.com/Azure/alz-bicep-accelerator"
)

$ErrorActionPreference = "Stop"

# Only what the Management and Connectivity deployments need
$Paths = @(
    "templates/core/logging"
    "templates/networking/hubnetworking"
    "templates/networking/virtualwan"
    "bicepconfig.json"
    "LICENSE"
)

$Destination = Join-Path $PSScriptRoot "upstream/alz-bicep-accelerator"
$WorkDir     = Join-Path ([IO.Path]::GetTempPath()) "alz-bicep-accelerator-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

try {
    # --------------------------------------------------------------
    # SPARSE SHALLOW CLONE (the governance library has paths longer
    # than MAX_PATH on Windows: only check out what is needed)
    # --------------------------------------------------------------
    Write-Host "Fetching $RepositoryUrl @ $Ref" -ForegroundColor Cyan
    git -c core.longpaths=true clone --quiet --depth 1 --branch $Ref --filter=blob:none --no-checkout $RepositoryUrl $WorkDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for ref '$Ref'" }

    git -C $WorkDir sparse-checkout set --no-cone @Paths
    git -C $WorkDir -c core.longpaths=true checkout --quiet $Ref
    if ($LASTEXITCODE -ne 0) { throw "git checkout failed for ref '$Ref'" }

    $Commit = git -C $WorkDir rev-parse HEAD

    # --------------------------------------------------------------
    # REPLACE THE VENDORED COPY
    # --------------------------------------------------------------
    if (Test-Path $Destination) {
        Remove-Item -Path $Destination -Recurse -Force
    }
    foreach ($Path in $Paths) {
        $Source = Join-Path $WorkDir $Path
        if (-not (Test-Path $Source)) { throw "'$Path' not found in $Ref - did the upstream layout change?" }

        $Target = Join-Path $Destination $Path
        New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
        Copy-Item -Path $Source -Destination $Target -Recurse -Force
    }

    @"
# Vendored - do not edit

Source : $RepositoryUrl
Ref    : $Ref
Commit : $Commit
Synced : $(Get-Date -Format "yyyy-MM-dd")

Refresh with ``..\..\Sync-Upstream.ps1 -Ref <tag>`` and review the git diff.
"@ | Set-Content -Path (Join-Path $Destination "VENDORED.md") -Encoding utf8

    Write-Host "Vendored $Ref ($($Commit.Substring(0, 7))) into $Destination" -ForegroundColor Green
}
finally {
    if (Test-Path $WorkDir) {
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
