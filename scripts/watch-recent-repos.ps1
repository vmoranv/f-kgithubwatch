#!/usr/bin/env pwsh
<#
.SYNOPSIS
Backfill watch subscriptions for recently created repositories.

.DESCRIPTION
Lists recently created repos for a user/org, then calls:
`PUT /repos/{owner}/{repo}/subscription`
with subscribed=true and ignored=false.

Designed for:
- Local one-shot backfill
- GitHub Actions scheduled sync

.PARAMETER Owner
GitHub login/organization name. If omitted, current authenticated user is used.

.PARAMETER OwnerType
auto|user|org

.PARAMETER Since
Only process repos created at/after this timestamp (converted to UTC).

.PARAMETER SinceDays
Only process repos created within the last N days.

.PARAMETER Limit
Max repositories to inspect (1..10000).

.PARAMETER DryRun
Only print targets, do not call write API.
#>

[CmdletBinding(DefaultParameterSetName = "Days", PositionalBinding = $false)]
param(
  [string] $Owner,

  [ValidateSet("auto", "user", "org")]
  [string] $OwnerType = "auto",

  [Parameter(ParameterSetName = "Since", Mandatory = $true)]
  [DateTime] $Since,

  [Parameter(ParameterSetName = "Days")]
  [ValidateRange(1, 3650)]
  [int] $SinceDays = 30,

  [ValidateRange(1, 10000)]
  [int] $Limit = 100,

  [switch] $DryRun,

  [switch] $IncludeArchived
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command([string] $Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

Require-Command "gh"

if (-not $Owner) {
  $Owner = (gh api user --jq ".login" 2>$null).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve current authenticated user via gh api user."
  }
}

if (-not $Owner) {
  throw "Failed to resolve owner login."
}

if ($OwnerType -eq "auto") {
  $entityType = (gh api "users/$Owner" --jq ".type" 2>$null).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve owner type for $Owner"
  }
  if ($entityType -eq "Organization") {
    $OwnerType = "org"
  } else {
    $OwnerType = "user"
  }
}

$baseEndpoint = if ($OwnerType -eq "org") {
  "orgs/$Owner/repos?sort=created&direction=desc&type=all"
} else {
  "users/$Owner/repos?sort=created&direction=desc&type=owner"
}

$cutoff = if ($PSCmdlet.ParameterSetName -eq "Since") {
  $Since.ToUniversalTime()
} else {
  (Get-Date).ToUniversalTime().AddDays(-$SinceDays)
}

$perPage = [Math]::Min(100, $Limit)

Write-Host "[watch-recent-repos] owner=$Owner ownerType=$OwnerType cutoff=$($cutoff.ToString('o')) limit=$Limit perPage=$perPage dryRun=$DryRun"
Write-Host "[watch-recent-repos] listing: $baseEndpoint"

$page = 1
$processed = 0
$watched = 0
$skipped = 0
$failed = 0

$stop = $false

while (-not $stop -and $processed -lt $Limit) {
  $pageEndpoint = "$baseEndpoint&per_page=$perPage&page=$page"
  Write-Host "[watch-recent-repos] fetching page=$page"

  $reposJson = gh api $pageEndpoint
  if ($LASTEXITCODE -ne 0) {
    throw "Failed listing repositories from endpoint: $pageEndpoint"
  }

  $repos = $reposJson | ConvertFrom-Json
  if (-not $repos) {
    break
  }

  foreach ($repo in $repos) {
    if ($processed -ge $Limit) {
      $stop = $true
      break
    }

    $processed += 1

    if (-not $IncludeArchived -and $repo.archived) {
      $skipped += 1
      continue
    }

    $createdAt = [DateTime]::Parse($repo.created_at).ToUniversalTime()
    if ($createdAt -lt $cutoff) {
      # Repos are sorted desc by created date, so we can stop early.
      $stop = $true
      break
    }

    $fullName = [string]$repo.full_name
    if (-not $fullName) {
      $skipped += 1
      continue
    }

    if ($DryRun) {
      Write-Host "[watch-recent-repos] DRY-RUN watch => $fullName"
      continue
    }

    try {
      gh api -X PUT "repos/$fullName/subscription" `
        -H "Accept: application/vnd.github+json" `
        -f subscribed=true `
        -f ignored=false `
        --silent
      if ($LASTEXITCODE -ne 0) {
        throw "gh api returned non-zero exit code."
      }
      $watched += 1
      Write-Host "[watch-recent-repos] watched $fullName"
    } catch {
      $failed += 1
      Write-Warning "[watch-recent-repos] failed $fullName :: $($_.Exception.Message)"
    }
  }

  if ($stop) {
    break
  }

  if ($repos.Count -lt $perPage) {
    break
  }

  $page += 1
}

Write-Host "[watch-recent-repos] summary processed=$processed watched=$watched skipped=$skipped failed=$failed cutoff=$($cutoff.ToString('o'))"

if ($failed -gt 0) {
  exit 1
}
