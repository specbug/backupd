# hostd

Single-host CI/CD and supervision for a self-hosted Podman box (one Mac mini).

An app declares itself in one `deploy.yml` at its repo root and carries no
hosting machinery of its own. hostd deploys it when its branch moves, keeps it
running, probes its health, and backs its data up to Cloudflare R2.

`SPEC.md` is the contract. It is the only thing an app needs to read.

This repo is also one of the hosted apps: **backupd**, the container at the
root, is an ordinary compose stack with no privileges the others lack.

## Onboarding an app

```yaml
# deploy.yml, at the app repo root
name: draw
branch: master

health:
  container: draw_api_1
  url: http://localhost:8100/health

backup:
  volume: draw-data
  jobs:
    - {type: sync, source: scenes/, destination: draw/scenes/}
```

```sh
hostd add ~/Documents/excalidraw   # after committing the manifest
git commit -am "onboard draw"      # the regenerated jobs.yml + compose.yml
hostd install
```

Every block is optional except `name`. No `health.url` means no HTTP probe; no
`backup` means no backup jobs.

## Running it

Two launchd agents run the same binary, however many apps are hosted.

| agent | every | does |
| --- | --- | --- |
| `in.sixeleven.hostd-watch` | 120s | podman machine up, stacks up, health probes |
| `in.sixeleven.hostd-deploy` | 300s | one `git ls-remote` per app, ff-merge, rebuild |

```sh
hostd status              # registry, deployed SHA vs HEAD, stack, health
hostd tick --dry-run      # what would deploy, changes nothing
hostd sync                # regenerate jobs.yml and compose.yml from manifests
hostd seed [name]         # adopt current HEAD as deployed, no build
hostd install             # install the binary, the registry and both agents
```

Deploys are pull-based, so there is no webhook, no public endpoint and no
shared secret. An app is skipped, with one log line, when its tree is dirty,
its checkout is off the tracked branch, the branch diverged, the watchdog holds
its lock, or that commit already failed to build three times. Fast-forward
only, never `reset --hard`, so an auto-deploy cannot eat uncommitted work.

Requires **Full Disk Access for `/opt/homebrew/bin/git`**, and `yq` on the host
(`brew install yq`). Under launchd macOS denies `~/Documents` per binary: git
and podman hold grants, bash does not. That is why manifests are read with
`git show` and the registry is installed to `~/.local/etc`. See `SPEC.md`.

## Tests

```sh
./framework/test.sh
```

39 assertions against a real git origin and real containers, isolated from the
live stacks. Needs `alpine:latest` locally.

## backupd

The backup container. Loops every `BACKUP_INTERVAL_SECONDS`, reads `jobs.yml`
and pushes to R2.

```sh
cp .env.example .env   # fill in R2 creds
podman compose up -d --build
podman logs -f backupd_backupd_1
```

`jobs.yml` and the `# >>> hostd:` blocks in `compose.yml` are **generated** by
`hostd sync` from every app's `deploy.yml`. Do not edit them by hand.

Job types:

- `sqlite`: hot backup via `sqlite3 .backup`, gzip, upload. Replaces the
  previous object. No versioning.
- `sync`: `rclone sync` a directory. Mirrors the source, so it deletes at the
  destination what is gone from the source.

`.env`:

| Var | |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | Target bucket |
| `BACKUP_INTERVAL_SECONDS` | Cycle interval (default 86400) |
