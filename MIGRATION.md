# Cutover to hostd

One-time. Delete this file once it is done.

**There is a script for all of this**, once the three PRs are merged and pulled:

```sh
./framework/cutover.sh --dry-run    # print every action, change nothing
./framework/cutover.sh              # do it
./framework/cutover.sh --rollback   # put the old agents back
```

It refuses to start unless all three repos are merged, clean and level with
origin, backs up everything it removes, and covers steps 2 through 5 below.
The rest of this file is what it does, for when you want to do it by hand or
understand what went wrong.

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

## 3. Seed first, then install

Order matters here. The agents carry `RunAtLoad=true`, so `hostd install`
bootstraps them and the deploy agent fires *immediately*. With no state it
treats every app as never-deployed and rebuilds all three from scratch,
including excalidraw's multi-minute vite build, recreating healthy containers
for no reason. Seeding first makes that first tick a no-op.

The registry is not installed yet at this point, so point at the repo's copy.
State lands in `~/.local/state/hostd` either way.

```sh
cd ~/Documents/backupd
HOSTD_CONF="$PWD/framework/apps.conf" ./framework/hostd seed
./framework/hostd install
./framework/hostd status
```

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

The framework outgrew the name. Do this **last**, once the above is stable, so
a rename cannot be confused with a cutover fault.

Note what does *not* change: the app is still called `backupd` in `deploy.yml`,
so the compose project, the container name `backupd_backupd_1` and the state
file `~/.local/state/hostd/backupd` are all untouched. Only the repository and
its directory are renamed.

```sh
gh repo rename hostd -R specbug/backupd     # GitHub redirects the old URL
cd ~/Documents && mv backupd hostd
cd hostd && git remote set-url origin git@github.com:specbug/hostd.git
git remote -v                                # confirm before continuing
```

The registry still points at the old path, so fix it and reinstall. `hostd
install` re-copies `apps.conf` to `~/.local/etc/hostd/`, which is what actually
takes effect:

```sh
sed -i '' 's|Documents/backupd|Documents/hostd|' framework/apps.conf
./framework/hostd sync
git commit -am "chore: rename backupd to hostd" && git push
./framework/hostd install
./framework/hostd status                     # all three apps must still resolve
```

Then update the one cross-repo reference: `../odyssey/CLAUDE.md` points at
`../backupd`. Commit that on its own branch.

If `status` shows `no manifest` for backupd afterwards, the registry path is
still stale: check `~/.local/etc/hostd/apps.conf`, not the one in the repo.

## Still outstanding

`draw_cloudflared_1` is not running, so `draw.sixeleven.in` is not served even
though the app is up on `localhost:3100`. That needs
`CLOUDFLARE_TUNNEL_TOKEN` in `~/Documents/excalidraw/.env`, plus the tunnel
ingress and the Cloudflare Access application. See that repo's
`self-host/INTEGRATION.md`. Unrelated to this cutover.
