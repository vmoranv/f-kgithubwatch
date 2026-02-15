#!/usr/bin/env pwsh
<#
.SYNOPSIS
Create a GitHub repo via `gh repo create` and immediately enable Watch via REST API.

.DESCRIPTION
Wraps `gh repo create` but adds:
- Ensures the repo exists
- Calls `PUT /repos/{owner}/{repo}/subscription` to set subscribed=true and ignored=false
- Verifies via `GET /repos/{owner}/{repo}/subscription`

Requires:
- gh CLI authenticated

Notes:
- The subscription endpoint does not support fine-grained PATs or GitHub App tokens.
  Locally, `gh api` uses your gh auth token; ensure it's a classic PAT if needed.

.EXAMPLE
.\scripts\new-repo-watch.ps1 my-org/my-repo --private --clone

.EXAMPLE
.\scripts\new-repo-watch.ps1 my-repo --public --source .\template
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string] $Repo,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $GhArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command([string] $Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

Require-Command "gh"

function Get-OwnerOverrideFromGhArgs([string[]] $args) {
  if (-not $args) {
    return $null
  }

  for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]
    if ($arg -eq "--org" -or $arg -eq "-o") {
      if ($i + 1 -lt $args.Count) {
        $owner = [string]$args[$i + 1]
        if (-not [string]::IsNullOrWhiteSpace($owner)) {
          return $owner.Trim()
        }
      }
      continue
    }

    if ($arg -match "^(--org|-o)=(.+)$") {
      $owner = $Matches[2]
      if (-not [string]::IsNullOrWhiteSpace($owner)) {
        return $owner.Trim()
      }
    }
  }

  return $null
}

function Resolve-RepoFullName([string] $repoArg, [string[]] $ghArgs) {
  # If user passed "owner/name" use it directly.
  if ($repoArg -match "^[^/]+/[^/]+$") {
    $ownerOverride = Get-OwnerOverrideFromGhArgs $ghArgs
    if ($ownerOverride) {
      throw "Repo argument already includes an owner ($repoArg) but --org/-o was also provided ($ownerOverride). Pick one."
    }
    return $repoArg
  }

  # If gh repo create targets an org, use that org as owner.
  $ownerOverride = Get-OwnerOverrideFromGhArgs $ghArgs
  if ($ownerOverride) {
    return "$ownerOverride/$repoArg"
  }

  # Otherwise resolve to current authenticated user.
  $login = (gh api user --jq ".login" 2>$null).Trim()
  if (-not $login) {
    throw "Failed to resolve current GitHub user login. Are you authenticated in gh?"
  }
  return "$login/$repoArg"
}

$fullName = Resolve-RepoFullName $Repo $GhArgs

Write-Host "[new-repo-watch] Creating repo: $fullName"

$createArgs = @("repo", "create", $fullName) + $GhArgs
& gh @createArgs
if ($LASTEXITCODE -ne 0) {
  throw "gh repo create failed for $fullName"
}

# Wait until repo is visible (eventual consistency).
Write-Host "[new-repo-watch] Waiting for repo to become available..."
$maxAttempts = 12
$isReady = $false
for ($i = 1; $i -le $maxAttempts; $i++) {
  gh api "repos/$fullName" --silent 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    $isReady = $true
    break
  }
  Start-Sleep -Seconds 2
}
if (-not $isReady) {
  throw "Repository was not available after $maxAttempts attempts: $fullName"
}

Write-Host "[new-repo-watch] Enabling Watch subscription..."

gh api -X PUT "repos/$fullName/subscription" `
  -H "Accept: application/vnd.github+json" `
  -f subscribed=true `
  -f ignored=false `
  --silent
if ($LASTEXITCODE -ne 0) {
  throw "Failed to set subscription for $fullName"
}

# Verify
$sub = gh api "repos/$fullName/subscription" --jq "{subscribed: .subscribed, ignored: .ignored, reason: .reason, created_at: .created_at, url: .url}"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to read subscription state for $fullName"
}
Write-Host "[new-repo-watch] Subscription state: $sub"

Write-Host "[new-repo-watch] Done: $fullName"
