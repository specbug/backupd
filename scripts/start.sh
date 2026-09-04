#!/bin/bash
# Ensures the Podman machine and the backupd stack are running.
# Invoked by launchd on login and every 2 min (StartInterval).
# Silent no-op when healthy; logs only on action.
#
# Mirrors odyssey/scripts/start.sh — see its header for the full rationale
# on single-instance locking, socket-readiness probing, and compose timeout.
# backupd has no HTTP health endpoint (it's a 24h rclone loop), so the
# "container in running state" check is the whole signal.
#
# IMPORTANT: launchd can't exec this file from ~/Documents due to macOS TCC.
# The real runtime copy lives at ~/.local/bin/backupd-start.
# After editing this script, re-copy:
#     cp scripts/start.sh ~/.local/bin/backupd-start && chmod +x ~/.local/bin/backupd-start
#     launchctl kickstart -k "gui/$UID/in.sixeleven.backupd"
set -euo pipefail

PODMAN=/opt/homebrew/bin/podman
PROJECT_DIR="/Users/rishitv/Documents/backupd"
CONTAINER="backupd_backupd_1"
LOCK=/tmp/in.sixeleven.backupd.lock
COMPOSE_TIMEOUT=120

log() { echo "[backupd-start] $(date '+%H:%M:%S') $*"; }

if ! mkdir "$LOCK" 2>/dev/null; then
    if [[ -f "$LOCK/pid" ]] && kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

socket_ready() { "$PODMAN" ps >/dev/null 2>&1; }

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

if ! socket_ready; then
    log "podman socket not ready, starting machine..."
    "$PODMAN" machine start 2>&1 | grep -v "already running" || true
    for _ in $(seq 1 60); do
        socket_ready && break
        sleep 2
    done
    if ! socket_ready; then
        log "machine socket never came up — will retry next cycle"
        exit 1
    fi
    log "socket ready."
fi

if ! "$PODMAN" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    log "$CONTAINER not running, bringing up stack..."
    cd "$PROJECT_DIR"
    if with_timeout "$COMPOSE_TIMEOUT" "$PODMAN" compose up -d >/tmp/backupd-start.compose.log 2>&1; then
        log "done."
    else
        log "compose up failed/timeout (see /tmp/backupd-start.compose.log) — next cycle will retry"
    fi
fi
