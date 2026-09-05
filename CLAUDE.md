# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

This repo is two things, and the split is the first thing to understand:

- **`framework/`** is **hostd**, which deploys and supervises every compose
  stack on this Mac mini. It is generic. Nothing app-specific belongs in it.
- **everything at the root** is **backupd**, one of the apps hostd hosts. It
  is a container that runs `backup.sh` in a loop and ships app data to R2.

`SPEC.md` is the contract between hostd and the apps. Read it before changing
either half. Host reliability (FileVault, auto-login, `pmset`, weekly reboot)
is in `../odyssey/CLAUDE.md` under *Reliability & Hosting*, the canonical
server runbook.

## hostd

Two launchd agents, both running the same binary, regardless of app count:

| agent | subcommand | every | does |
| --- | --- | --- | --- |
| `in.sixeleven.hostd-watch` | `hostd watch` | 120s | machine up, stacks up, health probes |
| `in.sixeleven.hostd-deploy` | `hostd tick` | 300s | `ls-remote` per app, ff-merge, rebuild |

```sh
hostd status                  # registry, deployed SHA vs HEAD, stack, health
hostd tick --dry-run          # what would deploy, changes nothing
hostd add ~/Documents/<app>   # register an app (needs a committed deploy.yml)
hostd rm <name>
hostd sync                    # regenerate jobs.yml + compose.yml from manifests
hostd seed [name]             # adopt current HEAD as deployed, no build
hostd install                 # install binary, registry and both agents

tail -f ~/Library/Logs/in.sixeleven.hostd-watch.log
launchctl kickstart -k "gui/$UID/in.sixeleven.hostd-deploy"   # tick now
```

### Editing the framework

`hostd` reinstalls itself after deploying this repo, so the normal path is
commit and push. To iterate locally without waiting for a tick, run
`hostd install` from the repo root.

`add`, `rm` and `sync` write into `~/Documents` and so only run from a login
shell. `watch` and `tick` never write there and run fine under launchd.

### The generated files

`jobs.yml` and the two `# >>> hostd:` blocks in `compose.yml` are output, not
input. Editing them by hand is wrong and will be overwritten. The input is the
`backup:` block of each app's `deploy.yml`. Change that, commit it, run
`hostd sync`.

### Non-obvious bits

- **TCC is per-binary and is the sharp edge.** Under launchd, bash cannot read
  anything under `~/Documents`; git and podman can, because they hold Full Disk
  Access. This is why manifests are read with `git show`, why the registry
  lives in `~/.local/etc`, and why the binary is executed from `~/.local/bin`.
  `cd` is permitted, which is what lets `compose up` work at all. Full detail
  and the failure signature are in `SPEC.md`.
- **Only `watch` starts the podman machine.** `tick` exits if the socket is
  down. Two concurrent `podman machine start` calls SIGTERM each other's
  gvproxy.
- **`podman ps` failing is not the same as nothing running.** The old
  watchdogs wrote `$(podman ps ... || true)`, which turned a transient failure
  into "every container is down" and fired a pointless `compose up` on 2928 of
  7890 logged ticks. `running_containers` distinguishes the two and retries
  once before believing an error.
- **Never pipe `podman ps` into `grep -q` under `pipefail`.** grep exits on the
  match, podman dies of SIGPIPE, the pipeline reports 141 and reads as "down".

## backupd

`backup.sh` is the container entrypoint. It loops every
`BACKUP_INTERVAL_SECONDS`, parses `jobs.yml`, and dispatches per job `type`:

- `sqlite`: `sqlite3 -readonly <src> ".backup /tmp/<name>.db"`, gzip,
  `rclone copyto`. Replaces the previous object every cycle. No versioning.
- `sync`: `rclone sync`. Additive for new files, destructive on the dest side.

```sh
podman compose up -d --build
podman logs -f backupd_backupd_1
podman compose down && podman compose up -d   # podman-compose skips recreate on .env change alone

# list what is in R2 (an exec'd shell does not inherit backup.sh's exports)
podman exec backupd_backupd_1 sh -c '
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_REGION=auto
  rclone ls r2:$R2_BUCKET --s3-no-check-bucket
'
```

No tests, no lint.

### Non-obvious bits

- rclone is configured only via `RCLONE_CONFIG_R2_*` env vars. No `rclone.conf`.
  The `NOTICE: Config file … not found - using defaults` line is expected.
- `yq` is the Go one (mikefarah). Syntax is `yq '.jobs[0].name'`. The host needs
  it too now, for hostd: `brew install yq`.
- Source volumes are mounted `:ro`, so `sqlite3 -readonly` is required: WAL-mode
  SQLite would otherwise try to open the DB read-write and fail.
- Every rclone call uses `--s3-no-check-bucket`. R2 tokens are scoped to one
  bucket, so the default `HeadBucket` precheck 403s.
- R2 key layout is `<app>/<resource-type>/<object>`. One bucket, per-app prefix.
- `jobs.yml` is read once at startup, so the container must be recreated after
  it changes. A deploy does that anyway.

### Gotchas

- `sqlite` jobs re-upload the full DB every cycle. Fine for small DBs; revisit
  if one grows to hundreds of MB.
- `rclone sync` deletes remote objects that vanish from source. Intentional
  mirror semantics, not retention.
- R2 free tier: 10 GB storage, 1M Class A ops/month, 10M Class B. Storage is
  the variable to watch as sync sources grow.
