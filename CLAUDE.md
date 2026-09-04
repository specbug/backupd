# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This repo holds two daemons for the Mac mini, sharing one host and one
runbook:

- **backupd**, the container. `backup.sh` in a loop, ships app data to R2.
- **deployd**, `scripts/deploy.sh`. Host-side, watches GitHub and rebuilds
  every compose stack on this box when its branch moves.

Everything at the repo root is container-side. Everything under `scripts/`
runs on the host.

## Autostart (macOS)

`scripts/backupd.plist` is the launchd agent that boots the stack on login. Installed at `~/Library/LaunchAgents/in.sixeleven.backupd.plist`, it invokes `~/.local/bin/backupd-start` (not the repo script directly — macOS TCC blocks launchd from executing files in `~/Documents/`).

Runs at login and every 2 min (`StartInterval=120`) as a watchdog: the
script ensures the podman machine is up and that `backupd_backupd_1` is
running. Silent no-op when healthy. Host-level reliability (FileVault,
auto-login, `pmset`, weekly reboot, etc.) is documented in
`../odyssey/CLAUDE.md` under *Reliability & Hosting* — that's the
canonical server runbook.

**After editing `scripts/start.sh`, re-copy it:**

```sh
cp scripts/start.sh ~/.local/bin/backupd-start && chmod +x ~/.local/bin/backupd-start
launchctl kickstart -k "gui/$UID/in.sixeleven.backupd"   # re-run now
```

**After editing `scripts/backupd.plist`:**

```sh
cp scripts/backupd.plist ~/Library/LaunchAgents/in.sixeleven.backupd.plist
launchctl bootout "gui/$UID/in.sixeleven.backupd" 2>/dev/null || true
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/in.sixeleven.backupd.plist
launchctl kickstart -k "gui/$UID/in.sixeleven.backupd"
```

## Commands

```sh
# build + start
podman compose up -d --build

# logs
podman logs -f backupd_backupd_1

# recreate after .env or compose.yml change (podman-compose skips recreate on env change alone)
podman compose down && podman compose up -d

# list what's in R2 (exec'd shell doesn't inherit the RCLONE_CONFIG_* exports from backup.sh)
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

No tests, no lint. Project is ~80 lines of shell and YAML.

## Architecture

`backup.sh` is the container entrypoint. It loops every `BACKUP_INTERVAL_SECONDS`, parses `jobs.yml`, and dispatches per job `type`:

- `sqlite`: `sqlite3 -readonly <src> ".backup /tmp/<name>.db"`, gzip, `rclone copyto`. Replaces the previous object every cycle. No versioning.
- `sync`: `rclone sync`. Additive for new files, destructive on the dest side (removes what's gone from source).

### Non-obvious bits

- rclone is configured only via `RCLONE_CONFIG_R2_*` env vars. No `rclone.conf` file. The `NOTICE: Config file … not found - using defaults` log line is expected, not an error.
- `yq` is the Go one (mikefarah/yq from Alpine's `yq` package). Syntax is `yq '.jobs[0].name'`, not the Python yq.
- Source volumes are mounted `:ro`. `sqlite3 -readonly` is required because WAL-mode SQLite would otherwise try to open the DB read-write and fail on the RO mount.
- Every rclone call uses `--s3-no-check-bucket`. R2 API tokens are scoped to one bucket so the default `HeadBucket` precheck 403s.
- backupd is a separate compose project that mounts volumes from other projects. The producing stack must set `name: <volume>` on its volume (e.g. odyssey uses `name: odyssey-data`) so Podman skips the project prefix. backupd then references it as `external: true, name: <volume>`.
- R2 key layout is `<app>/<resource-type>/<object>`. One bucket, per-app top-level prefix.

### Adding a new backup job

1. `compose.yml`: mount the app's volume at `/sources/<app>:ro`, declare it external.
2. `jobs.yml`: append `name`, `type`, `source` (path in container), `destination` (R2 key).
3. `podman compose up -d`.

`jobs.yml` is read once at startup. A restart is required after editing it.

## Gotchas

- `podman compose up -d` alone may not pick up `.env` changes. Use `down && up -d`.
- `sqlite` jobs re-upload the full DB every cycle. Fine for small DBs; revisit if one grows to hundreds of MB.
- `rclone sync` deletes remote objects that vanish from source. Intentional (mirror semantics) but not retention.
- R2 free tier: 10 GB storage, 1M Class A ops/month, 10M Class B. Storage is the variable to watch as sync sources grow.

## deployd (auto-deploy on push)

`scripts/deploy.sh` redeploys every compose stack on this Mac when its
GitHub branch moves. Pull-based: one `git ls-remote` per app per tick. No
webhook, no public endpoint, no secrets. Registry is `scripts/apps.conf`,
one line per stack, currently odyssey and backupd (it deploys this repo
too).

`scripts/deployd.plist` is its launchd agent, `in.sixeleven.deployd`,
separate from the backupd watchdog above. Installed at
`~/Library/LaunchAgents/`, invokes `~/.local/bin/deployd`, runs at login
and every 5 min (`StartInterval=300`).

### Installing deployd

```sh
cp scripts/deploy.sh ~/.local/bin/deployd && chmod +x ~/.local/bin/deployd
~/.local/bin/deployd --seed          # adopt what's running now, no rebuild
cp scripts/deployd.plist ~/Library/LaunchAgents/in.sixeleven.deployd.plist
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/in.sixeleven.deployd.plist
```

**After editing `scripts/deploy.sh`, re-copy it** (same TCC reason as
`start.sh`):

```sh
cp scripts/deploy.sh ~/.local/bin/deployd && chmod +x ~/.local/bin/deployd
launchctl kickstart -k "gui/$UID/in.sixeleven.deployd"
```

`scripts/apps.conf` is read fresh every tick, so registry edits need no
restart. It is read from `~/Documents/backupd/scripts/apps.conf` at
runtime, the one file the agent reads out of `~/Documents`. Traversal works
there (both watchdogs already `cd` into `~/Documents`); only exec is blocked.

### deployd commands

```sh
deployd --dry-run      # report what would deploy, change nothing
deployd --seed         # adopt the checked-out HEAD as deployed, no build
deployd                # one tick, for real
tail -f ~/Library/Logs/deployd.log
launchctl kickstart -k "gui/$UID/in.sixeleven.deployd"   # tick now
```

### One tick, per app

1. `git ls-remote origin refs/heads/<branch>` for the remote SHA.
2. Compare against `~/.local/state/deployd/<app>`, the SHA last deployed.
   Equal is the common case and exits silently.
3. Guards: on the tracked branch, tree clean, this SHA hasn't already failed.
4. Take `/tmp/in.sixeleven.<app>.lock`.
5. `git fetch` and `git merge --ff-only`, then `podman compose up -d --build`
   with a 900s kill-timeout.
6. On success record the SHA and `podman image prune -f`. On failure record
   it in `<app>.failed` and hold at the old SHA.

### deployd, non-obvious bits

- **State is the deployed SHA, not local HEAD.** This Mac is both the dev
  machine and the server. Pushing from here leaves HEAD equal to origin
  while the containers still run the old image, so a HEAD-vs-remote check
  would see no work and the stack would drift. Deployed-SHA state also makes
  a failed build self-retrying and survives a reboot mid-deploy.
- **The app lock is the integration point with the watchdogs.** odyssey and
  backupd both implement the same mkdir-plus-pid lock protocol in their
  `start.sh`. deployd holds the app's own lock across fetch and build so a
  watchdog cannot `compose up` against a half-updated tree. This is why
  `<name>` in `apps.conf` must equal the watchdog label suffix.
- **deployd never starts the podman machine.** The per-app watchdogs own
  that. Two concurrent `podman machine start` calls SIGTERM each other's
  gvproxy, which is a documented way to collapse the stack. If the socket is
  down, deployd exits and waits.
- **`--ff-only`, never `reset --hard`.** These are live working copies, so a
  dirty tree or a diverged branch means "skip and log", not "force".
- **The failed-SHA file exists to stop a rebuild loop.** Otherwise a commit
  that fails to build rebuilds every tick forever. A newer commit clears it.
- **`--seed` records HEAD, not origin's tip.** It is a claim about what the
  running containers were built from. Seeding a repo whose origin is ahead
  leaves those commits to deploy on the next tick, which is what you want.
  First run without `--seed` rebuilds every app once to establish a baseline.
- `deploy_app` is called with `</dev/null`. git shells out to ssh, which
  drains stdin and would otherwise eat the rest of `apps.conf` in the read
  loop.

### deployd, deliberate omissions

- **No rollback.** Health is covered by compose healthchecks, the per-app
  watchdogs, Healthchecks.io and UptimeRobot. Roll back by reverting and
  pushing, which deployd picks up on its own.
- **No secret management.** `.env` files stay hand-managed. A commit that
  needs a new env var deploys fine and then fails its healthcheck.
- **Compose stacks only.** `odyssey/apps/mac` is a native app, not hosted.

### deployd gotchas

- A dirty working copy means that app is skipped, quietly, except for one
  log line per tick. Check the log if a deploy "didn't happen".
- Working on a branch here means backupd stops auto-deploying until it is
  merged back to `main`. Intended, but easy to forget.
- `jobs.yml` edits ship this way too, since the container is recreated.
