# backupd

Backs up SQLite DBs and file trees from Podman volumes to Cloudflare R2. Runs in a container, loops on a fixed interval, reads jobs from a YAML file.

## Usage

```sh
cp .env.example .env   # fill in R2 creds
podman compose up -d --build
podman logs -f backupd_backupd_1
```

## Adding an app

1. Mount its volume in `compose.yml` at `/sources/<app>:ro`. The producing stack must declare its volume with a stable name (e.g. `name: myapp-data` in the app's compose) so Podman skips the project prefix.
2. Append to `jobs.yml`:

   ```yaml
   - name: myapp-db
     type: sqlite
     source: /sources/myapp/app.db
     destination: myapp/db/app.db.gz
   ```
3. `podman compose up -d`.

## Job types

- `sqlite`: hot backup via `sqlite3 .backup`, gzip, upload. Replaces previous. No versioning.
- `sync`: `rclone sync` a directory. Mirrors the source (deletes at dest if gone from source).

## Config

`.env`:

| Var | |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account ID |
| `R2_ACCESS_KEY_ID` | R2 API token access key |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |
| `R2_BUCKET` | Target bucket |
| `BACKUP_INTERVAL_SECONDS` | Cycle interval (default 86400) |

`jobs.yml`: list of `{ name, type, source, destination }`.
