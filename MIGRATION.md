# Cutover to hostd

One-time. Delete this file once it is done.

Replaces three launchd agents (`in.sixeleven.odyssey`, `in.sixeleven.backupd`,
`in.sixeleven.deployd`) with two (`in.sixeleven.hostd-watch`,
`in.sixeleven.hostd-deploy`), and three hand-maintained scripts with one.

## Before you start

`brew install yq` on the host. hostd reads manifests with it.

While the three repos sit on their feature branches, the **old** deployd skips
all of them (checkout is off the tracked branch) and logs one line per tick.
That is the guard working, not a fault, but auto-deploy is paused until the
branches merge.

## 1. Merge

```sh
cd ~/Documents/odyssey    && git checkout main   && git merge --ff-only feat/adopt-hostd
cd ~/Documents/excalidraw && git checkout master && git merge --ff-only feat/adopt-hostd
cd ~/Documents/backupd    && git checkout main   && git merge --ff-only feat/hostd-framework
```

Push all three. Nothing takes effect yet: the old agents do not know about
`deploy.yml`, and the new ones are not installed.

## 2. Stop the old agents

```sh
for a in odyssey backupd deployd; do
  launchctl bootout "gui/$UID/in.sixeleven.$a" 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/in.sixeleven.$a.plist
done
rm -f ~/.local/bin/odyssey-start ~/.local/bin/backupd-start ~/.local/bin/deployd
rm -f ~/.local/etc/deployd.conf
```

The containers keep running. Nothing is supervising them for the next minute.

## 3. Install hostd

```sh
cd ~/Documents/backupd
./framework/hostd install
./framework/hostd seed          # adopt the running containers, no rebuild
./framework/hostd status
```

`seed` matters. Without it the first tick rebuilds all three stacks from
scratch, including excalidraw's multi-minute vite build.

Old deploy state under `~/.local/state/deployd/` is now unused and can go.

## 4. Verify

```sh
launchctl kickstart -k "gui/$UID/in.sixeleven.hostd-watch"
launchctl kickstart -k "gui/$UID/in.sixeleven.hostd-deploy"
tail -20 ~/Library/Logs/in.sixeleven.hostd-watch.log
./framework/hostd status
```

A healthy watch pass logs nothing. `status` should show all three apps `up`,
odyssey and draw `ok`, and DEPLOYED equal to HEAD.

Then leave it for ten minutes and check the watch log again. It should still be
empty. The old watchdogs logged a spurious "not running, bringing up stack" on
roughly 37% of ticks; if that pattern reappears, the `podman ps` failure
handling in `running_containers` did not fix it and it needs a real diagnosis.

## 5. Rename the repo

The framework outgrew the name. Do this last, after the above is stable.

```sh
gh repo rename hostd -R specbug/backupd
cd ~/Documents && mv backupd hostd
cd hostd && git remote set-url origin git@github.com:specbug/hostd.git
```

Then update the registry path and reinstall:

```sh
sed -i '' 's|Documents/backupd|Documents/hostd|' framework/apps.conf
./framework/hostd sync && git commit -am "chore: rename backupd to hostd"
./framework/hostd install
```

Also update `../odyssey/CLAUDE.md`, which refers to `../backupd`.

## Still outstanding

`draw_cloudflared_1` is not running, so `draw.sixeleven.in` is not served even
though the app is up on `localhost:3100`. That needs
`CLOUDFLARE_TUNNEL_TOKEN` in `~/Documents/excalidraw/.env`, plus the tunnel
ingress and the Cloudflare Access application. See that repo's
`self-host/INTEGRATION.md`. Unrelated to this cutover.
