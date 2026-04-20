#!/usr/bin/env bash
# backupd — iterate jobs.yml every BACKUP_INTERVAL_SECONDS, push to R2.
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

run_sqlite_job() {
  local name="$1" src="$2" dest="$3"
  local tmp="/tmp/${name//\//_}.db"
  rm -f "$tmp" "${tmp}.gz"
  sqlite3 -readonly "$src" ".backup '$tmp'"
  gzip -f "$tmp"
  rclone copyto --s3-no-check-bucket "${tmp}.gz" "r2:${R2_BUCKET}/${dest}"
  rm -f "${tmp}.gz"
}

run_sync_job() {
  local src="$1" dest="$2"
  rclone sync --s3-no-check-bucket "$src" "r2:${R2_BUCKET}/${dest}"
}

run_all_jobs() {
  local count
  count="$(yq '.jobs | length' "$JOBS_FILE")"
  for i in $(seq 0 $((count - 1))); do
    local name type src dest
    name="$(yq ".jobs[$i].name"        "$JOBS_FILE")"
    type="$(yq ".jobs[$i].type"        "$JOBS_FILE")"
    src="$(yq  ".jobs[$i].source"      "$JOBS_FILE")"
    dest="$(yq ".jobs[$i].destination" "$JOBS_FILE")"
    log "job '$name' ($type) $src -> r2:${R2_BUCKET}/${dest}"
    case "$type" in
      sqlite) run_sqlite_job "$name" "$src" "$dest" ;;
      sync)   run_sync_job           "$src" "$dest" ;;
      *) log "unknown job type '$type' for '$name' — skipping"; continue ;;
    esac
    log "job '$name' done"
  done
}

[[ -r "$JOBS_FILE" ]] || { log "jobs file not readable: $JOBS_FILE"; exit 1; }

while true; do
  log "starting backup cycle"
  if run_all_jobs; then
    log "cycle complete; sleeping ${INTERVAL}s"
  else
    log "cycle failed; sleeping ${INTERVAL}s before retry"
  fi
  sleep "$INTERVAL"
done
