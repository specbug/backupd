# backupd

Containerized backup daemon. Pushes SQLite DBs and file trees from local Podman/Docker volumes to Cloudflare R2 on a fixed interval.

## What it does

- **`sqlite` jobs** — hot backup via `sqlite3 -readonly … .backup`, gzip, upload (replaces previous object).
- **`sync` jobs** — `rclone sync` a directory tree (skips unchanged files).

One daemon, one loop, reads jobs from `jobs.yml`. Fully virtualized — no host cron, no host tools beyond Podman.

## Quick start

```sh
cp .env.example .env   # fill in R2 creds
podman compose up -d --build
podman logs -f backupd_backupd_1
```

## Adding a new app

1. Mount its volume read-only in `compose.yml` under `/sources/<app>`:
   ```yaml
   volumes:
     - myapp-data:/sources/myapp:ro
   ```
   (The volume must use a stable top-level name — declare `name: myapp-data` in the app's compose file so it isn't project-prefixed.)

2. Append job entries to `jobs.yml`:
   ```yaml
   - name: myapp-db
     type: sqlite
     source: /sources/myapp/app.db
     destination: myapp/db/app.db.gz
   ```

3. `podman compose up -d`.

## Config

### `.env`
| Var | Purpose |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | Target bucket name |
| `BACKUP_INTERVAL_SECONDS` | Cycle interval (default `86400` = 24h) |

### `jobs.yml`
Each job: `name`, `type` (`sqlite` \| `sync`), `source` (path inside container), `destination` (key prefix in R2 bucket).

## Layout

```
backup.sh    # daemon entrypoint — loops and dispatches jobs
jobs.yml     # declarative backup jobs
compose.yml  # single-service stack, mounts external volumes
Dockerfile   # alpine + sqlite + rclone + yq
```
