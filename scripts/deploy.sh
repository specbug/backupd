#!/bin/bash
# deployd, the deploy half of this repo. Redeploys the compose stacks on
# this Mac when their origin branch moves. Pull-based: one `git ls-remote`
# per app per tick, no webhook, no inbound surface.
#
# Host-side, like scripts/start.sh. Nothing here runs in the container.
#
# For each app in apps.conf:
#   origin/<branch> moved?  ->  fast-forward the working copy, rebuild.
#
# Compares against the SHA we last *deployed*, not local HEAD. This box is
# both the dev machine and the server, so a push from here leaves HEAD ==
# origin while the containers still run the old image. Local HEAD says
# nothing about what is running.
#
# Silent no-op when nothing moved. Logs only on action.
#
# IMPORTANT: launchd can't exec this file from ~/Documents (macOS TCC).
# The runtime copy lives at ~/.local/bin/deployd. After editing:
#     cp scripts/deploy.sh ~/.local/bin/deployd && chmod +x ~/.local/bin/deployd
#     launchctl kickstart -k "gui/$UID/in.sixeleven.deployd"
#
# Flags:
#   --dry-run   report what would deploy, change nothing
#   --seed      adopt the checked-out HEAD as deployed, without building
set -euo pipefail

PODMAN=/opt/homebrew/bin/podman
CONF="${DEPLOYD_CONF:-/Users/rishitv/Documents/backupd/scripts/apps.conf}"
STATE_DIR="$HOME/.local/state/deployd"
LOCK=/tmp/in.sixeleven.deployd.lock
BUILD_TIMEOUT=900

MODE=run
case "${1:-}" in
    --dry-run) MODE=dry ;;
    --seed)    MODE=seed ;;
    "")        ;;
    *) echo "usage: $0 [--dry-run|--seed]" >&2; exit 2 ;;
esac

log() { echo "[deployd] $(date '+%H:%M:%S') $*"; }

# mkdir-based lock with a pid file. Identical protocol to the per-app
# watchdogs in odyssey/backupd start.sh, so holding an app's lock is enough
# to stop its watchdog running `compose up` underneath a build.
acquire() {
    local lock="$1"
    if ! mkdir "$lock" 2>/dev/null; then
        if [[ -f "$lock/pid" ]] && kill -0 "$(cat "$lock/pid" 2>/dev/null)" 2>/dev/null; then
            return 1
        fi
        rm -rf "$lock"
        mkdir "$lock" 2>/dev/null || return 1
    fi
    echo "$$" > "$lock/pid"
}

# Same kill-timeout wrapper the watchdogs use. A wedged build must not hold
# the app lock forever.
with_timeout() {
    local secs="$1"; shift
    "$@" &
    local cmd_pid=$!
    (
        sleep "$secs"
        kill -TERM "$cmd_pid" 2>/dev/null && sleep 3
        kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    local killer_pid=$!
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    kill "$killer_pid" 2>/dev/null || true
    wait "$killer_pid" 2>/dev/null || true
    return "$rc"
}

compose_up() { cd "$1" && "$PODMAN" compose up -d --build; }

deploy_app() {
    local name="$1" path="$2" branch="$3"
    local state="$STATE_DIR/$name" failed="$STATE_DIR/$name.failed"
    local remote deployed current rc=0

    if [[ ! -d "$path/.git" ]]; then
        log "$name: $path is not a git repo, skipping"
        return 0
    fi

    # Seed records the checked-out HEAD, not origin's tip: it is claiming
    # "this is what the running containers were built from". Recording origin
    # instead would make deployd skip commits it has never built, silently.
    if [[ "$MODE" == seed ]]; then
        mkdir -p "$STATE_DIR"
        git -C "$path" rev-parse HEAD > "$state"
        rm -f "$failed"
        log "$name: seeded at $(cut -c1-8 "$state")"
        return 0
    fi

    remote=$(git -C "$path" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    if [[ -z "$remote" ]]; then
        log "$name: can't reach origin/$branch, will retry next tick"
        return 0
    fi

    deployed=$(cat "$state" 2>/dev/null || true)
    [[ "$remote" == "$deployed" ]] && return 0

    # A commit that failed to build is not retried until a newer one lands.
    # Without this, one bad commit rebuilds on every tick, forever.
    if [[ "$remote" == "$(cat "$failed" 2>/dev/null || true)" ]]; then
        return 0
    fi

    local shown="${deployed:0:8}"
    log "$name: origin/$branch at ${remote:0:8}, deployed ${shown:-none}"

    # Guards. Anything unexpected about the working copy means skip and say
    # so, never force. An auto-deploy must not be able to lose your work.
    current=$(git -C "$path" rev-parse --abbrev-ref HEAD)
    if [[ "$current" != "$branch" ]]; then
        log "$name: checked out on '$current', not '$branch', skipping"
        return 0
    fi
    if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
        log "$name: working tree dirty, skipping (commit, stash or push to resume)"
        return 0
    fi

    if [[ "$MODE" == dry ]]; then
        log "$name: DRY RUN, would fast-forward to ${remote:0:8} and rebuild"
        return 0
    fi

    local app_lock="/tmp/in.sixeleven.$name.lock"
    if ! acquire "$app_lock"; then
        log "$name: watchdog holds the lock, retrying next tick"
        return 0
    fi

    local build_log="/tmp/deployd-$name.compose.log"
    git -C "$path" fetch --quiet origin "$branch" \
        && git -C "$path" merge --ff-only --quiet "$remote" \
        && with_timeout "$BUILD_TIMEOUT" compose_up "$path" >"$build_log" 2>&1 \
        || rc=$?
    rm -rf "$app_lock"

    if (( rc != 0 )); then
        mkdir -p "$STATE_DIR"
        echo "$remote" > "$failed"
        log "$name: deploy failed (rc=$rc), see $build_log. Holding at ${deployed:0:8}, will not retry ${remote:0:8}"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    echo "$remote" > "$state"
    rm -f "$failed"
    "$PODMAN" image prune -f >/dev/null 2>&1 || true
    log "$name: deployed ${remote:0:8}"
}

if [[ ! -f "$CONF" ]]; then
    log "no app registry at $CONF"
    exit 1
fi

# One deployd run at a time. A build can outlast a tick.
if ! acquire "$LOCK"; then
    exit 0
fi
trap 'rm -rf "$LOCK"' EXIT

# Don't start the podman machine here. Each app's watchdog already does
# that, and two concurrent `podman machine start` calls SIGTERM each
# other's gvproxy. If the socket is down, wait for them.
if ! "$PODMAN" ps >/dev/null 2>&1; then
    exit 0
fi

# stdin is redirected per call: git shells out to ssh, which would
# otherwise drain the registry we are reading and skip every app but the first.
while read -r name path branch _; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    deploy_app "$name" "$path" "${branch:-main}" </dev/null
done < "$CONF"
