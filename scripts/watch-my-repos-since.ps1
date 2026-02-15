#!/usr/bin/env pwsh
<#
.SYNOPSIS
One-click watch enable for your own repos created after a timestamp.

.DESCRIPTION
Wrapper around ./scripts/watch-recent-repos.ps1 with defaults:
- owner: current authenticated user
- owner type: user
- since: 2025-04-14T00:00:00Z

.EXAMPLE
.\scripts\watch-my-repos-since.ps1

.EXAMPLE
.\scripts\watch-my-repos-since.ps1 -Since "2025-08-01T00:00:00Z" -Limit 2000 -DryRun
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [DateTime] $Since = ([DateTime]::Parse("2025-04-14T00:00:00Z").ToUniversalTime()),

  [ValidateRange(1, 10000)]
  [int] $Limit = 1000,

  [switch] $DryRun,

  [switch] $IncludeArchived
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptArgs = @{
  OwnerType = "user"
  Since = $Since.ToUniversalTime()
  Limit = $Limit
}

if ($DryRun) {
  $scriptArgs.DryRun = $true
}

if ($IncludeArchived) {
  $scriptArgs.IncludeArchived = $true
}

& "$PSScriptRoot/watch-recent-repos.ps1" @scriptArgs

