#!/usr/bin/env bash
# backupd — iterate jobs.yml every BACKUP_INTERVAL_SECONDS, push to R2 and,
# when configured, mirror to Google Drive.
set -euo pipefail

JOBS_FILE="${JOBS_FILE:-/etc/backupd/jobs.yml}"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"  # 24h
: "${R2_ACCOUNT_ID:?required}" "${R2_ACCESS_KEY_ID:?required}" \
  "${R2_SECRET_ACCESS_KEY:?required}" "${R2_BUCKET:?required}"

# Configure rclone via env so no config file is needed.
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export RCLONE_CONFIG_R2_REGION=auto

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# --- google drive, the secondary -------------------------------------------
# R2 is the primary of record. Drive exists because R2 has no versioning, so
# it must never be able to fail the R2 leg, fail a cycle, or hold the primary
# hostage by crash-looping the container: a misconfiguration degrades to
# R2-only and says so on every cycle instead of exiting.
GDRIVE_ON=0
GDRIVE_OFF_REASON="not enabled"
GDRIVE_FAILURES=0
VERSIONS_DIR="${GDRIVE_VERSIONS_DIR:-_versions}"
CYCLE_DATE=""

case "${GDRIVE_ENABLED:-}" in
  1 | true | TRUE | yes | on)
    if [[ -z "${GDRIVE_TOKEN:-}" || -z "${GDRIVE_ROOT_FOLDER_ID:-}" ]]; then
      GDRIVE_OFF_REASON="enabled but GDRIVE_TOKEN or GDRIVE_ROOT_FOLDER_ID is empty"
    else
      GDRIVE_ON=1
      export RCLONE_CONFIG_GDRIVE_TYPE=drive
      # Full 'drive' scope, not 'drive.file': the latter only sees files the
      # app itself created, so it cannot resolve a pre-existing folder id.
      export RCLONE_CONFIG_GDRIVE_SCOPE=drive
      export RCLONE_CONFIG_GDRIVE_TOKEN="$GDRIVE_TOKEN"
      # Rooting the remote at the sixeleven.in folder is what makes a job's
      # 'destination' remote-agnostic: the same key addresses both remotes.
      export RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID="$GDRIVE_ROOT_FOLDER_ID"
      # Left blank, rclone uses its own published OAuth client, whose refresh
      # tokens do not expire. A self-made client left in "Testing" publishing
      # status expires them every 7 days, which is the quiet way this dies.
      if [[ -n "${GDRIVE_CLIENT_ID:-}" ]]; then
        export RCLONE_CONFIG_GDRIVE_CLIENT_ID="$GDRIVE_CLIENT_ID"
      fi
      if [[ -n "${GDRIVE_CLIENT_SECRET:-}" ]]; then
        export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET="$GDRIVE_CLIENT_SECRET"
      fi
    fi
    ;;
esac

remotes_desc() {
  if (( GDRIVE_ON )); then
    printf 'r2 (primary) + gdrive (secondary)'
  else
    printf 'r2 only — gdrive %s' "$GDRIVE_OFF_REASON"
  fi
}

# Overwritten and deleted objects are moved here rather than lost, which is
# the whole point of the second mirror: a corrupt or truncated source would
# otherwise propagate to both remotes on the next cycle. The path mirrors the
# live layout, so two jobs cannot collide in one dated archive.
gdrive_backup_dir() { printf 'gdrive:%s/%s/%s' "$VERSIONS_DIR" "$CYCLE_DATE" "$1"; }

# Counted, logged, never fatal. Says nothing about how the R2 leg fared: that
# is reported separately, and this also fires for the prune, which has no R2
# counterpart.
gdrive_failed() {
  log "  gdrive: $1 FAILED — secondary only, continuing"
  GDRIVE_FAILURES=$(( GDRIVE_FAILURES + 1 ))
}

# Dated buckets are pruned to the newest GDRIVE_VERSIONS_KEEP. With a daily
# cycle that is a recovery *window*, not a per-file version count: the point of
# the archive is to still be there when corruption is noticed late, and only
# churned bytes land in a bucket, so a generous default is nearly free.
#
# Only ISO-dated directories this script created are ever purged, so anything
# filed under _versions/ by hand is left alone. Drive's own trash still holds
# purged objects for ~30 days.
gdrive_prune_versions() {
  local keep="${GDRIVE_VERSIONS_KEEP:-90}" all dated total excess d
  (( GDRIVE_ON )) || return 0
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0

  all="$(rclone lsf --dirs-only "gdrive:${VERSIONS_DIR}" 2>/dev/null)" || return 0
  # ISO-8601 names sort lexically, so the newest N are simply the tail.
  dated="$(printf '%s\n' "$all" | sed 's:/$::' \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort)" || return 0
  total="$(printf '%s\n' "$dated" | grep -c . )" || total=0
  (( total > keep )) || return 0
  excess=$(( total - keep ))

  while read -r d; do
    [[ -n "$d" ]] || continue
    if rclone purge "gdrive:${VERSIONS_DIR}/${d}" >/dev/null 2>&1; then
      log "  gdrive: pruned version bucket $d"
    else
      gdrive_failed "prune of version bucket '$d'"
    fi
  done <<EOF
$(printf '%s\n' "$dated" | head -n "$excess")
EOF
  log "  gdrive: kept newest $keep of $total version buckets"
}

# --- remotes ---------------------------------------------------------------
# Status is tracked and returned by hand rather than left to `set -e`. Since
# run_all_jobs is called as `if run_all_jobs`, bash disables errexit for the
# whole dynamic extent of that call, so a failing rclone here neither aborts
# nor propagates on its own: before this was explicit, three failed R2 uploads
# still logged "job done" and "cycle complete", which is the worst way for a
# backup to break.
#
# A failing job does not stop the ones after it either. One broken app must not
# cost every other app its backup that cycle.

# One local file to every remote. An R2 failure fails the job; a Drive failure
# is counted and swallowed. The legs are independent, so Drive is still
# attempted when R2 is down — a copy there is worth having either way.
push_file() {
  local src="$1" dest="$2" rc=0
  if ! rclone copyto --s3-no-check-bucket "$src" "r2:${R2_BUCKET}/${dest}"; then
    log "  r2: copy of '$dest' FAILED"
    rc=1
  fi
  if (( GDRIVE_ON )); then
    rclone copyto "$src" "gdrive:${dest}" \
      --backup-dir "$(gdrive_backup_dir "$(dirname "$dest")")" \
      --drive-stop-on-upload-limit \
      || gdrive_failed "copy of '$dest'"
  fi
  return "$rc"
}

# One directory tree to every remote, mirror semantics.
push_dir() {
  local src="$1" dest="$2" rc=0
  if ! rclone sync --s3-no-check-bucket "$src" "r2:${R2_BUCKET}/${dest}"; then
    log "  r2: sync of '$dest' FAILED"
    rc=1
  fi
  if (( GDRIVE_ON )); then
    rclone sync "$src" "gdrive:${dest}" \
      --backup-dir "$(gdrive_backup_dir "$dest")" \
      --drive-stop-on-upload-limit \
      || gdrive_failed "sync of '$dest'"
  fi
  return "$rc"
}

# Snapshot once, ship to every remote: one sqlite3 .backup rather than one per
# remote, so both destinations provably receive identical bytes.
run_sqlite_job() {
  local name="$1" src="$2" dest="$3" rc=0
  local tmp="/tmp/${name//\//_}.db"
  rm -f "$tmp" "${tmp}.gz"
  if ! sqlite3 -readonly "$src" ".backup '$tmp'"; then
    log "  sqlite: snapshot of '$src' FAILED, nothing uploaded"
    rm -f "$tmp"
    return 1
  fi
  if ! gzip -f "$tmp"; then
    log "  gzip of the '$name' snapshot FAILED, nothing uploaded"
    rm -f "$tmp" "${tmp}.gz"
    return 1
  fi
  push_file "${tmp}.gz" "$dest" || rc=1
  rm -f "${tmp}.gz"
  return "$rc"
}

run_sync_job() {
  local src="$1" dest="$2"
  push_dir "$src" "$dest"
}

run_all_jobs() {
  local count failures=0
  count="$(yq '.jobs | length' "$JOBS_FILE")" \
    || { log "cannot read jobs from $JOBS_FILE"; return 1; }
  [[ "$count" =~ ^[0-9]+$ ]] \
    || { log "$JOBS_FILE: job count is '$count', not a number"; return 1; }
  (( count > 0 )) || { log "$JOBS_FILE declares no jobs"; return 0; }

  for i in $(seq 0 $((count - 1))); do
    local name type src dest rc=0
    name="$(yq ".jobs[$i].name"        "$JOBS_FILE")"
    type="$(yq ".jobs[$i].type"        "$JOBS_FILE")"
    src="$(yq  ".jobs[$i].source"      "$JOBS_FILE")"
    dest="$(yq ".jobs[$i].destination" "$JOBS_FILE")"
    log "job '$name' ($type) $src -> $dest"
    case "$type" in
      sqlite) run_sqlite_job "$name" "$src" "$dest" || rc=1 ;;
      sync)   run_sync_job           "$src" "$dest" || rc=1 ;;
      # An unrecognised type counts as a failure: jobs.yml is generated, so it
      # means either a bad manifest or a malformed generated file, and either
      # way nothing was uploaded for this job. Reporting a clean cycle there
      # would hide it.
      *) log "unknown job type '$type' for '$name' — skipping"
         failures=$(( failures + 1 )); continue ;;
    esac
    if (( rc )); then
      log "job '$name' FAILED"
      failures=$(( failures + 1 ))
    else
      log "job '$name' done"
    fi
  done

  (( failures == 0 ))
}

[[ -r "$JOBS_FILE" ]] || { log "jobs file not readable: $JOBS_FILE"; exit 1; }

# Probe Drive once at startup so a bad token or folder id is visible in the
# log immediately rather than mid-cycle. Advisory only: a blip here must not
# disable the mirror for the life of the container.
if (( GDRIVE_ON )); then
  if rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1; then
    log "gdrive: reachable, rooted at folder $GDRIVE_ROOT_FOLDER_ID"
  else
    log "gdrive: WARNING — probe failed (token, folder id or network); will still be attempted per job"
  fi
fi

while true; do
  CYCLE_DATE="$(date -u +%F)"
  GDRIVE_FAILURES=0
  log "starting backup cycle — $(remotes_desc)"
  if run_all_jobs; then status=0; else status=1; fi
  gdrive_prune_versions

  if (( status != 0 )); then
    log "cycle FAILED — at least one job did not reach R2"
  elif (( GDRIVE_FAILURES )); then
    log "cycle complete, R2 current, $GDRIVE_FAILURES gdrive failure(s)"
  else
    log "cycle complete"
  fi

  # BACKUP_ONCE runs a single cycle and exits with its status, so a backfill
  # or a verification run can be triggered by hand instead of waiting out
  # BACKUP_INTERVAL_SECONDS.
  if [[ -n "${BACKUP_ONCE:-}" ]]; then
    exit "$status"
  fi

  log "sleeping ${INTERVAL}s"
  sleep "$INTERVAL"
done
