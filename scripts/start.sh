#!/bin/bash
# Starts the Podman machine (if needed) and brings up the backupd stack.
# Invoked by the launchd agent on login.
#
# IMPORTANT: launchd can't exec this file from ~/Documents due to macOS TCC.
# The real runtime copy lives at ~/.local/bin/backupd-start.
# After editing this script, re-copy:
#     cp scripts/start.sh ~/.local/bin/backupd-start && chmod +x ~/.local/bin/backupd-start
set -euo pipefail

PODMAN=/opt/homebrew/bin/podman
# Hardcoded: the installed copy at ~/.local/bin/ can't resolve this relative to the repo.
PROJECT_DIR="/Users/rishitv/Documents/backupd"

log() { echo "[backupd-start] $*"; }

if ! "$PODMAN" machine inspect 2>/dev/null | grep -q '"State": "running"'; then
    log "Starting Podman machine..."
    "$PODMAN" machine start
    sleep 15
else
    log "Podman machine already running."
fi

log "Starting compose stack..."
cd "$PROJECT_DIR"
"$PODMAN" compose up -d --build

log "Done."
