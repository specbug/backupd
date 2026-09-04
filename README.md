# backupd

Two daemons for a self-hosted Podman host.

- **backupd**, a container: backs app data up to Cloudflare R2.
- **deployd**, `scripts/deploy.sh`: rebuilds every compose stack on the host
  when its GitHub branch moves.

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

## Deploys

`scripts/deploy.sh` polls each repo in `scripts/apps.conf` every 5 minutes.
When the tracked branch moves it fast-forwards the working copy and runs
`podman compose up -d --build`. Pull-based, so there is no webhook, no public
endpoint and no shared secret.

```sh
cp scripts/deploy.sh ~/.local/bin/deployd && chmod +x ~/.local/bin/deployd
~/.local/bin/deployd --seed          # adopt what's running now, no rebuild
cp scripts/deployd.plist ~/Library/LaunchAgents/in.sixeleven.deployd.plist
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/in.sixeleven.deployd.plist
```

Add a stack with one line in `scripts/apps.conf`:

```
<name>  <repo path>  <branch>
```

`<name>` must match the app's watchdog label suffix (`in.sixeleven.<name>`),
since deployd takes that lock before rebuilding.

It skips an app, and says so in `~/Library/Logs/deployd.log`, when the working
tree is dirty, the checkout is off the tracked branch, the branch diverged, a
watchdog holds the lock, or that commit already failed to build. Fast-forward
only, never `reset --hard`, so an auto-deploy cannot eat uncommitted work.

No rollback: revert and push, and deployd picks it up.
