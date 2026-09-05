# The hostd app contract

hostd deploys and supervises compose stacks on one Mac mini. This document is
the contract between it and the apps it hosts.

The rule it exists to enforce: **the app declares, the framework disposes.**
An app describes itself in one file and owns no hosting machinery. hostd owns
all of it, once, for everyone.

## Onboarding, in full

1. Add `deploy.yml` to the app repo root. Commit and push it.
2. On the host, from the hostd repo: `hostd add ~/Documents/<app>`
3. Commit the regenerated `jobs.yml` and `compose.yml`, then `hostd install`.

There is no third file. No LaunchAgent, no watchdog script, no supervisor, no
entry to hand-edit in a registry, no per-app anything inside hostd.

## The manifest

`deploy.yml`, at the app repo root.

```yaml
name: draw                 # required. [a-z0-9-]+. Names the lock, the state
                           # file, the /sources mount and the log lines.
branch: master             # optional, default `main`. The branch hostd deploys.

health:
  container: draw_api_1    # required for supervision. The container whose
                           # presence in `podman ps` means "the stack is up".
  url: http://localhost:8100/health   # optional. No url means no HTTP probe,
                           # and "the container exists" is the whole signal.
  restart: draw_api_1      # optional, defaults to health.container. What gets
                           # bounced when the probe fails three times.

build:
  timeout: 1800            # optional, default 900. Seconds before a build is
                           # SIGKILLed so it cannot hold the app lock forever.

backup:
  volume: draw-data        # optional. A podman volume, mounted read-only at
                           # /sources/<name> in the backup container.
  jobs:                    # source paths are relative to the volume root.
    - name: draw-scenes    # optional, defaults to <name>-<index>.
      type: sync           # `sync` (rclone mirror) or `sqlite` (hot backup).
      source: scenes/
      destination: draw/scenes/    # key under the R2 bucket.
```

Omitting a block opts out of that capability. No `health.url` means no probe;
no `backup` means no backup jobs. An app with only `name` still gets deployed.

### What the app still owns

- A `compose.yml` at its repo root that `podman compose up -d --build` can run.
- Any volume it wants backed up must be declared with a global `name:`, so
  Podman skips the project prefix and another project can mount it.
- Its own `.env`. hostd manages no secrets, deliberately.

## What hostd guarantees

**Deploy.** Every 300s, one `git ls-remote` per app. If `origin/<branch>` has
moved, fast-forward the working copy and `compose up -d --build`.

**Supervision.** Every 120s, ensure the podman machine is up, then for each app
ensure `health.container` is running, and if `health.url` is set, probe it three
times five seconds apart and restart `health.restart` if all three fail.

**Backups.** Volumes and jobs from every manifest are compiled into the backup
container's `compose.yml` and `jobs.yml` by `hostd sync`.

## Design decisions, and why

**State is the deployed SHA, not local HEAD.** This Mac is both the dev machine
and the server, so pushing from here leaves HEAD equal to origin while the
containers still run the old image. A HEAD-versus-remote check would see no
work and the stack would silently drift. Deployed-SHA state also makes a failed
build self-retrying and survives a reboot mid-deploy.

**Reading app manifests goes through git, never `cat`.** Under launchd, macOS
TCC denies bash every read inside `~/Documents`, while git and podman hold Full
Disk Access. Measured on this box: `cat`, `ls` and `[[ -d ... ]]` against a repo
path all fail with "Operation not permitted", while `git -C <repo>` works, and
`cd` is permitted. So hostd reads `git -C <repo> show HEAD:deploy.yml` and pipes
it to yq, which only ever touches stdin. Before the Full Disk Access grant on
`/opt/homebrew/bin/git` existed (granted 2026-09-04), git did not fail, it
**hung forever** waiting on a consent dialog that never appears for a background
agent. That grant is a manual GUI setting and is not in version control. If
hostd starts hanging or logging "unreadable manifest", check it first.

Reading the committed blob rather than the working copy is also the correct
semantics: a deploy only ever ships committed state, so hosting facts should
change the same way code does.

**One watchdog process for all apps.** Two concurrent `podman machine start`
calls SIGTERM each other's gvproxy, which is a documented way to collapse the
whole stack. When each app carried its own watchdog this was avoided by
convention. With a single pass that starts the machine at most once, it is
impossible.

**The app lock is the interlock between the two agents.** `hostd tick` holds
`/tmp/hostd.<name>.lock` across fetch and build so the watchdog cannot
`compose up` against a half-updated tree. The watchdog holds the same lock
while it acts. The loser skips and retries next pass.

**Generated artifacts are committed, not resolved at runtime.** `hostd sync`
rewrites `jobs.yml` and the marked blocks in `compose.yml`. What the backup
container will do is therefore visible in a diff before it happens, and it
deploys through the same path as everything else.

**`--ff-only`, never `reset --hard`.** These are live working copies. A dirty
tree or a diverged branch means "skip and log", not "force". An auto-deploy
must not be able to lose your work.

**Failures retry three times, then stop.** A commit that cannot build would
otherwise rebuild every tick forever. But not on the first failure: a build
starts milliseconds after git rewrote the tree, and the podman VM's view of a
just-replaced file can be briefly stale. Observed in testing, a commit failed
and the identical commit then succeeded with nothing changed. A newer commit
clears the failed marker.

**hostd reinstalls itself.** After deploying the repo that contains
`framework/hostd`, `hostd tick` writes the new copy to `~/.local/bin/hostd` via
`git show` (git can read what bash cannot) and an atomic `mv`, so the running
script keeps its own inode. Pushing a framework change is all that is required
to ship it. This removes the "remember to re-copy the script" step that the
previous design repeated in three places.

## Deliberate omissions

- **No rollback.** Roll back by reverting and pushing. hostd picks it up.
- **No secret management.** `.env` files stay hand-managed. A commit needing a
  new variable deploys fine and then fails its healthcheck, which is the
  intended signal.
- **No multi-host.** One Mac. If that changes, this is the wrong tool.
- **Compose stacks only.** A native app is not a hosted app.

## Failure modes worth knowing

- A dirty working copy means that app is skipped, quietly, one log line per
  tick. Working on a branch means the app stops auto-deploying until it is
  merged back. Intended, easy to forget, check the log if a deploy "did not
  happen".
- An uncommitted `deploy.yml` change has no effect. hostd reads HEAD.
- A job's `destination` addresses every remote: R2, and Google Drive rooted at
  the `sixeleven.in` folder. Drive is best-effort — a failed Drive leg is
  logged, never fatal, and never delays or fails the R2 leg.
- `rclone sync` deletes remote objects that vanish from the source. Mirror
  semantics, not retention.
