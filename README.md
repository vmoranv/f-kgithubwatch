# Auto Watch for Newly Created GitHub Repos

This repository restores "auto watch new repositories" behavior with:

1. A local `gh repo create` wrapper that immediately enables Watch.
2. An auto GitHub Actions workflow that continuously backfills recent repos.
3. A one-click script to watch your own repos after a cutoff date.
4. A dedicated manual GitHub Action for one-click cutoff backfill (default `2025-04-14T00:00:00Z`).

## Why this exists

GitHub's built-in "Automatically watch repositories" setting is not always enough for modern workflows.
This repo enforces Watch state via API:

- `PUT /repos/{owner}/{repo}/subscription`

## Prerequisites

- `gh` CLI installed and authenticated.
- PowerShell 7+ (`pwsh`) recommended.
- For Actions mode: a classic PAT stored as `WATCH_PAT` repository secret.

Important:

- The repository subscription endpoint does **not** work with GitHub App tokens and fine-grained PATs.
- In GitHub Actions, default `GITHUB_TOKEN` is a GitHub App token, so use `WATCH_PAT`.

## Local mode: create and watch immediately

```powershell
pwsh -File .\scripts\new-repo-watch.ps1 my-org/my-new-repo --private --clone
```

Create in an organization (repo arg without owner):

```powershell
pwsh -File .\scripts\new-repo-watch.ps1 my-new-repo --org my-org --private --clone
```

Equivalent flow:

1. Run `gh repo create ...`
2. Resolve real repo owner/name
3. Call subscription API to set `subscribed=true`, `ignored=false`
4. Verify watch state

## Local mode: backfill recent repos

Watch repos created recently by a user or org:

```powershell
pwsh -File .\scripts\watch-recent-repos.ps1 -Owner my-org -OwnerType org -SinceDays 30 -Limit 100
```

Watch repos created after a specific timestamp:

```powershell
pwsh -File .\scripts\watch-recent-repos.ps1 -Owner my-org -OwnerType org -Since "2026-02-01T00:00:00Z" -Limit 1000
```

One-click for your own repos (default: after `2025-04-14T00:00:00Z`):

```powershell
pwsh -File .\scripts\watch-my-repos-since.ps1
```

Override cutoff:

```powershell
pwsh -File .\scripts\watch-my-repos-since.ps1 -Since "2025-08-01T00:00:00Z" -Limit 2000
```

Dry run:

```powershell
pwsh -File .\scripts\watch-recent-repos.ps1 -Owner my-org -OwnerType org -DryRun
```

## Optional template-like alias

Make a reusable local command:

```powershell
gh alias set rnew "!pwsh -NoProfile -File $PWD/scripts/new-repo-watch.ps1"
```

Then:

```powershell
gh rnew my-org/my-new-repo --private --clone
```

## GitHub Actions mode

### A) Auto mode (continuous sync)

Workflow file: `.github/workflows/auto-watch-new-repos.yml`

Triggers:

- schedule: hourly
- manual `workflow_dispatch`

Default values:

- `owner`: empty (uses authenticated user)
- `owner_type`: `auto`
- `since_days`: `3`
- `limit`: `500`

### B) Manual one-click cutoff mode

Workflow file: `.github/workflows/manual-watch-since.yml`

Triggers:

- manual `workflow_dispatch`

Default manual values:

- `owner`: empty (uses authenticated user)
- `owner_type`: `user`
- `since`: `2025-04-14T00:00:00Z`
- `limit`: `1000`
- `dry_run`: `false`

Setup:

1. Create classic PAT.
2. Add PAT to repository secret `WATCH_PAT`.
3. Enable workflow.

The workflow executes:

```powershell
./scripts/watch-recent-repos.ps1
```

with inputs for owner, owner type, cutoff timestamp, and scan limit.

## References

- GitHub REST API: Watching endpoints  
  https://docs.github.com/en/rest/activity/watching
- GitHub CLI: `gh repo create`  
  https://cli.github.com/manual/gh_repo_create
