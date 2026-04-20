# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Autostart (macOS)

`scripts/backupd.plist` is the launchd agent that boots the stack on login. Installed at `~/Library/LaunchAgents/in.sixeleven.backupd.plist`, it invokes `~/.local/bin/backupd-start` (not the repo script directly — macOS TCC blocks launchd from executing files in `~/Documents/`).

**After editing `scripts/start.sh`, re-copy it:**

```sh
cp scripts/start.sh ~/.local/bin/backupd-start && chmod +x ~/.local/bin/backupd-start
launchctl kickstart -k "gui/$UID/in.sixeleven.backupd"   # re-run now
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
