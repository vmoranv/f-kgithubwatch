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

.PARAMETER SinceDays
Only process repos created within the last N days.

.PARAMETER Limit
Max repositories to inspect (1..100).

.PARAMETER DryRun
Only print targets, do not call write API.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [string] $Owner,

  [ValidateSet("auto", "user", "org")]
  [string] $OwnerType = "auto",

  [ValidateRange(1, 3650)]
  [int] $SinceDays = 30,

  [ValidateRange(1, 100)]
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

$endpoint = if ($OwnerType -eq "org") {
  "orgs/$Owner/repos?sort=created&direction=desc&per_page=$Limit&type=all"
} else {
  "users/$Owner/repos?sort=created&direction=desc&per_page=$Limit&type=owner"
}

Write-Host "[watch-recent-repos] owner=$Owner ownerType=$OwnerType sinceDays=$SinceDays limit=$Limit dryRun=$DryRun"
Write-Host "[watch-recent-repos] listing: $endpoint"

$reposJson = gh api $endpoint
if ($LASTEXITCODE -ne 0) {
  throw "Failed listing repositories from endpoint: $endpoint"
}
$repos = $reposJson | ConvertFrom-Json

if (-not $repos) {
  Write-Host "[watch-recent-repos] no repositories found."
  exit 0
}

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$SinceDays)
$processed = 0
$watched = 0
$skipped = 0
$failed = 0

foreach ($repo in $repos) {
  $processed += 1

  if (-not $IncludeArchived -and $repo.archived) {
    $skipped += 1
    continue
  }

  $createdAt = [DateTime]::Parse($repo.created_at).ToUniversalTime()
  if ($createdAt -lt $cutoff) {
    # Repos are sorted desc by created date, so we can stop early.
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

Write-Host "[watch-recent-repos] summary processed=$processed watched=$watched skipped=$skipped failed=$failed cutoff=$($cutoff.ToString('o'))"

if ($failed -gt 0) {
  exit 1
}
