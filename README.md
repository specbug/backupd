# hostd

Single-host CI/CD and supervision for a self-hosted Podman box (one Mac mini).

An app declares itself in one `deploy.yml` at its repo root and carries no
hosting machinery of its own. hostd deploys it when its branch moves, keeps it
running, probes its health, and backs its data up to Cloudflare R2, with a
second copy on Google Drive.

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

```sh
./test.sh
```

37 assertions for `backup.sh`, with rclone and sqlite3 stubbed, so it needs no
credentials, no network and no container. Run after touching either file.

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
  previous object. The snapshot is taken once and shipped to both remotes, so
  they provably hold identical bytes.
- `sync`: `rclone sync` a directory. Mirrors the source, so it deletes at the
  destination what is gone from the source.

## Two remotes

R2 is the primary and takes every read and write. Google Drive is a second copy
that exists because R2 has no object versioning.

A job's `destination` is remote-agnostic — the Drive remote is rooted at the
`sixeleven.in` folder, so `odyssey/db/odyssey.db.gz` addresses both
`r2:<bucket>/odyssey/db/odyssey.db.gz` and the same path under `sixeleven.in`.
Layouts stay identical and `deploy.yml` needs nothing new.

Drive is strictly secondary and cannot take the primary down:

- A failed Drive leg is logged and counted; the R2 leg and the cycle still
  succeed.
- Missing or malformed Drive settings degrade to R2-only, logged once per cycle,
  rather than crash-looping the container.
- `GDRIVE_ENABLED` unset means Drive is entirely off and behaviour is
  byte-identical to before it existed.

Mirroring alone would not protect against corruption — a truncated source
propagates to both remotes on the next cycle — so the Drive leg runs with
`--backup-dir`. Overwritten and deleted objects move to a dated bucket beside
the live mirror instead of disappearing:

```
sixeleven.in/odyssey/uploads/…            # live mirror, same layout as R2
sixeleven.in/_versions/2026-09-05/…       # what that cycle overwrote or deleted
```

Only churned bytes land there. The newest `GDRIVE_VERSIONS_KEEP` buckets are
kept and older ones purged; with a daily cycle that is a recovery *window*, not
a per-file version count. Only `NNNN-NN-NN` directories are ever purged, so
anything filed under `_versions/` by hand is left alone, and Drive's own trash
holds purged objects for ~30 days on top of that.

Setup is one command on a machine with a browser:

```sh
rclone authorize "drive"    # prints a JSON token -> GDRIVE_TOKEN in .env
```

Then `GDRIVE_ROOT_FOLDER_ID` is the last path segment of the `sixeleven.in`
folder's URL. Blank `GDRIVE_CLIENT_ID`/`_SECRET` uses rclone's own published
OAuth client, whose refresh tokens do not expire — a self-made client left in
"Testing" publishing status expires them every 7 days.

Backfilling existing data needs no special tooling: every job is a full
idempotent mirror, so the first cycle with Drive enabled uploads everything,
sourced from the read-only volumes rather than copied out of R2. To run one
cycle now instead of waiting out the interval:

```sh
podman exec -e BACKUP_ONCE=1 backupd_backupd_1 /usr/local/bin/backup.sh
```

`.env`:

| Var | |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | Target bucket |
| `BACKUP_INTERVAL_SECONDS` | Cycle interval (default 86400) |
| `GDRIVE_ENABLED` | Unset means no Drive leg at all |
| `GDRIVE_TOKEN` | JSON blob from `rclone authorize "drive"` |
| `GDRIVE_ROOT_FOLDER_ID` | Folder id of `sixeleven.in` |
| `GDRIVE_CLIENT_ID` / `_SECRET` | Optional; blank uses rclone's own OAuth client |
| `GDRIVE_VERSIONS_DIR` | Archive prefix (default `_versions`) |
| `GDRIVE_VERSIONS_KEEP` | Dated buckets to keep (default 90) |
| `BACKUP_ONCE` | Run one cycle and exit with its status |
