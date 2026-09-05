#!/bin/bash
# Harness for backup.sh. Run it directly: ./test.sh
#
# Unit-shaped, unlike framework/test.sh: rclone, sqlite3 and gzip are replaced
# by stubs that record their argv, so this asserts on the commands backup.sh
# *issues* rather than on bytes landing in a real bucket. That is deliberate —
# the properties worth guarding are dispatch and failure isolation, and neither
# needs credentials, a network, or a container.
#
# Needs bash and yq. Touches nothing outside its own temp dir, and by
# construction cannot reach R2 or Google Drive.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/backup.sh"
ROOT="${TMPDIR:-/tmp}/backupd-test"
PASS=0; FAIL=0

rm -rf "$ROOT"; mkdir -p "$ROOT/bin"

# Stubs. TRACE collects argv; FAIL_MATCH makes a remote fail on demand, which
# is how the primary/secondary split gets tested without breaking anything.
cat > "$ROOT/bin/rclone" <<'STUB'
#!/bin/bash
echo "rclone $*" >> "$TRACE"
if [[ -n "${FAIL_MATCH:-}" && "$*" == *"$FAIL_MATCH"* ]]; then exit 7; fi
if [[ "$*" == *"lsf --dirs-only"* ]]; then cat "${LSF_FIXTURE:-/dev/null}"; fi
exit 0
STUB
cat > "$ROOT/bin/sqlite3" <<'STUB'
#!/bin/bash
echo "sqlite3 $*" >> "$TRACE"
[[ -n "${SQLITE_FAILS:-}" ]] && exit 3
# Emulate `.backup '<tmp>'` producing a snapshot for gzip to consume.
t="$(printf '%s' "$*" | sed -n "s/.*\.backup '\([^']*\)'.*/\1/p")"
[[ -n "$t" ]] && echo snapshot > "$t"
exit 0
STUB
chmod +x "$ROOT/bin"/*
export PATH="$ROOT/bin:$PATH"

# Shaped like a real generated jobs.yml: one sqlite job, two syncs, two apps.
cat > "$ROOT/jobs.yml" <<'JOBS'
jobs:
  - name: odyssey-db
    type: sqlite
    source: /sources/odyssey/odyssey.db
    destination: odyssey/db/odyssey.db.gz
  - name: odyssey-uploads
    type: sync
    source: /sources/odyssey/uploads/
    destination: odyssey/uploads/
  - name: draw-scenes
    type: sync
    source: /sources/draw/scenes/
    destination: draw/scenes/
JOBS

export R2_ACCOUNT_ID=acct R2_ACCESS_KEY_ID=ak R2_SECRET_ACCESS_KEY=sk
export R2_BUCKET=test-bucket
export JOBS_FILE="$ROOT/jobs.yml"
export BACKUP_ONCE=1

ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

# Each case starts from a clean trace and a known env.
setup() {
  export TRACE="$ROOT/trace"; : > "$TRACE"
  unset FAIL_MATCH SQLITE_FAILS LSF_FIXTURE GDRIVE_VERSIONS_KEEP
  unset GDRIVE_ENABLED GDRIVE_TOKEN GDRIVE_ROOT_FOLDER_ID
}
gdrive_on() {
  export GDRIVE_ENABLED=true GDRIVE_TOKEN='{"refresh_token":"stub"}'
  export GDRIVE_ROOT_FOLDER_ID=STUBFOLDER
}
run()      { OUT="$(bash "$SUT" 2>&1)"; RC=$?; }
traced()   { grep -c "$1" "$TRACE"; }
# R2 legs carry --s3-no-check-bucket between the verb and the path; Drive legs
# do not. Counting them needs patterns that cannot match the other remote.
r2_legs()  { grep -cE '(copyto|sync) --s3-no-check-bucket .* r2:' "$TRACE"; }
gd_legs()  { grep -cE '(copyto|sync) [^ ]+ gdrive:' "$TRACE"; }
logged()   { grep -c "$1" <<<"$OUT"; }

echo "backup.sh"

echo
echo "gdrive disabled — must behave as it did before Drive existed"
setup; run
check "cycle succeeds"          "$RC" 0
check "every job reaches R2"    "$(r2_legs)" 3
check "Drive never mentioned"   "$(traced gdrive)" 0

echo
echo "gdrive enabled — fan-out"
setup; gdrive_on; run
check "cycle succeeds"              "$RC" 0
check "every job reaches R2"        "$(r2_legs)" 3
check "every job reaches Drive"     "$(gd_legs)" 3
check "each Drive leg archives"     "$(traced '\-\-backup-dir')" 3
check "snapshot taken once, not per remote" "$(traced '^sqlite3')" 1
check "Drive rooted at the folder"  "$(logged 'rooted at folder STUBFOLDER')" 1

echo
echo "Drive is secondary — its failures must not reach the primary"
setup; gdrive_on; export FAIL_MATCH=gdrive:; run
check "cycle still succeeds"        "$RC" 0
check "every job still reaches R2"  "$(r2_legs)" 3
check "jobs still report done"      "$(logged "job '.*' done")" 3
check "failures counted and named"  "$(logged '3 gdrive failure')" 1

echo
echo "R2 is primary — its failures must fail the cycle loudly"
# Regression test: errexit is disabled inside `if run_all_jobs`, so before
# status was tracked by hand, three failed uploads logged "cycle complete".
setup; gdrive_on; export FAIL_MATCH=r2:; run
check "cycle fails"                 "$RC" 1
check "and says so"                 "$(logged 'cycle FAILED')" 1
check "every job reported FAILED"   "$(logged "job '.*' FAILED")" 3
check "no job claims to be done"    "$(logged "job '.*' done")" 0
check "Drive still attempted"       "$(gd_legs)" 3

echo
echo "one bad job must not cost the other apps their backup"
setup; gdrive_on; export FAIL_MATCH=r2:test-bucket/odyssey/uploads; run
check "cycle fails"            "$RC" 1
check "exactly one job failed" "$(logged "job '.*' FAILED")" 1
check "the rest succeeded"     "$(logged "job '.*' done")" 2
check "all three attempted"    "$(r2_legs)" 3

echo
echo "a failed snapshot must upload nothing for that job"
setup; gdrive_on; export SQLITE_FAILS=1; run
check "cycle fails"                "$RC" 1
check "no half-made DB uploaded"   "$(traced 'odyssey.db.gz')" 0
check "sync jobs unaffected on R2" "$(r2_legs)" 2
check "sync jobs unaffected on Drive" "$(gd_legs)" 2

echo
echo "misconfigured Drive degrades to R2-only rather than exiting"
setup; gdrive_on; export GDRIVE_TOKEN=""; run
check "cycle succeeds"        "$RC" 0
check "every job reaches R2"  "$(r2_legs)" 3
check "says it is R2-only"    "$(logged 'r2 only')" 1
check "Drive never called"    "$(traced gdrive)" 0

echo
echo "unreadable or malformed jobs.yml uploads nothing"
setup; gdrive_on
printf 'jobs: not-a-list\n' > "$ROOT/bad.yml"
JOBS_FILE="$ROOT/bad.yml" run
check "cycle fails"          "$RC" 1
check "nothing uploaded"     "$(grep -cE '(copyto|sync) /' "$TRACE")" 0

echo
echo "version buckets are pruned to the newest N"
setup; gdrive_on
{ for d in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "2026-08-$d/"; done
  echo "filed-by-hand/"; } | sort -r > "$ROOT/lsf"
export LSF_FIXTURE="$ROOT/lsf" GDRIVE_VERSIONS_KEEP=10
run
check "purged down to the limit"   "$(traced purge)" 2
check "and purged the oldest two"  "$(grep -cE 'purge gdrive:_versions/2026-08-0[12]$' "$TRACE")" 2
check "kept the newest"            "$(grep -c 'purge gdrive:_versions/2026-08-12' "$TRACE")" 0
check "left a hand-made folder be" "$(grep -c 'purge gdrive:_versions/filed-by-hand' "$TRACE")" 0

setup; gdrive_on; export LSF_FIXTURE="$ROOT/lsf" GDRIVE_VERSIONS_KEEP=notanumber
run
check "a bad keep count disables pruning" "$(traced purge)" 0

printf '\n=====================\n  %d passed, %d failed\n=====================\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
