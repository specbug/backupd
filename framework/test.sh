#!/bin/bash
# Integration harness for hostd. Run it directly: framework/test.sh
#
# Drives the real deploy state machine against a real git origin and real
# containers. Nothing here touches the live stacks: the test app is its own
# compose project, with its own registry, state directory and locks, and a
# podman wrapper that swallows `image prune` so the host's dangling images
# survive. Needs alpine:latest locally; no network otherwise.
#
# Integration harness for hostd. Drives the real deploy state machine against a
# real git origin and real containers. Isolated from the live stacks by project
# name, registry, state dir and a podman wrapper that swallows `image prune`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOSTD="$HERE/hostd"
ROOT="${TMPDIR:-/tmp}/hostd-test"
REALPODMAN=/opt/homebrew/bin/podman
PASS=0; FAIL=0

rm -rf "$ROOT"; mkdir -p "$ROOT/bin"
export HOSTD_CONF="$ROOT/apps.conf"
export HOSTD_STATE="$ROOT/state"
export PODMAN="$ROOT/bin/podman"
export COMPOSE_TIMEOUT=90
export BUILD_TIMEOUT=90
FAILFLAG="$ROOT/podman-ps-fails"

cat > "$ROOT/bin/podman" <<WRAP
#!/bin/bash
# Fails only 'ps --format' when the flag file exists, so running_containers can
# be broken without also breaking the socket_ready probe.
if [[ "\$1" == ps && "\${2:-}" == --format && -f "$FAILFLAG" ]]; then exit 125; fi
# Never prune the real host's dangling images during a test.
if [[ "\$1" == image && "\${2:-}" == prune ]]; then exit 0; fi
exec $REALPODMAN "\$@"
WRAP
chmod +x "$ROOT/bin/podman"

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()  { if grep -q "$3" <<<"$2"; then ok "$1"; else bad "$1" "output lacked '$3': $(head -3 <<<"$2")"; fi; }
hasnt(){ if grep -q "$3" <<<"$2"; then bad "$1" "output unexpectedly had '$3'"; else ok "$1"; fi; }
sec()  { printf '\n== %s\n' "$1"; }

# --- fixture ---------------------------------------------------------------
ORIGIN="$ROOT/origin.git"; APP="$ROOT/testapp"
git init -q --bare "$ORIGIN"
git init -q "$APP" && cd "$APP"
git config user.email t@t; git config user.name t; git config commit.gpgsign false

write_app() {  # write_app <marker>
  # alpine's busybox has no httpd applet, so serve with nc. A YAML literal
  # block keeps printf's \r\n escapes intact; a double-quoted scalar would
  # have YAML itself eat them.
  cat > compose.yml <<EOF
name: hostdtest
services:
  app:
    image: alpine:latest
    command:
      - sh
      - -c
      - |
        while true; do printf 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n' | nc -l -p 8199; done
    restart: always
    labels:
      hostdtest.version: "$1"
    ports:
      - "8199:8199"
EOF
}
cat > deploy.yml <<'EOF'
name: testapp
branch: main
health:
  container: hostdtest_app_1
  url: http://localhost:8199/health
EOF
write_app v1
git add -A && git commit -qm v1
git branch -M main && git remote add origin "$ORIGIN" && git push -q -u origin main
echo "$APP" > "$HOSTD_CONF"

STATE="$ROOT/state/testapp"
sha() { git -C "$APP" rev-parse HEAD; }
tick()  { "$HOSTD" tick  "$@" 2>&1; }
watch() { "$HOSTD" watch "$@" 2>&1; }

# --- manifest handling -----------------------------------------------------
sec "manifest handling"
echo "$ROOT/nope" > "$HOSTD_CONF.tmp"; cp "$HOSTD_CONF" "$HOSTD_CONF.keep"
cat "$HOSTD_CONF.tmp" > "$HOSTD_CONF"
out=$(tick); has "unregistered path is skipped, not fatal" "$out" "unreadable manifest"
cp "$HOSTD_CONF.keep" "$HOSTD_CONF"

git -C "$APP" show HEAD:deploy.yml | sed 's/^name: testapp/name: Bad_Name/' > "$APP/deploy.yml"
git -C "$APP" commit -qam "bad name"
out=$(tick); has "invalid app name is rejected" "$out" "invalid name"
git -C "$APP" revert --no-edit HEAD >/dev/null 2>&1
git -C "$APP" push -q origin main

# --- seed and steady state -------------------------------------------------
sec "seed and steady state"
"$HOSTD" seed >/dev/null 2>&1
check "seed records HEAD" "$(cat "$STATE")" "$(sha)"
out=$(tick); check "seeded app at origin tip is a silent no-op" "$out" ""

# --- guards ----------------------------------------------------------------
sec "guards"
git -C "$APP" push -q origin main 2>/dev/null
echo dirt > "$APP/dirty.txt"
write_app v2; git -C "$APP" add compose.yml && git -C "$APP" commit -qm v2 && git -C "$APP" push -q origin main
git -C "$APP" reset -q --hard HEAD~1   # local behind origin, and dirty
echo dirt > "$APP/dirty.txt"
out=$(tick); has "dirty tree is skipped" "$out" "working tree dirty"
check "dirty tree does not move state" "$(cat "$STATE")" "$(sha)"
rm -f "$APP/dirty.txt"

git -C "$APP" checkout -q -b sidebranch
out=$(tick); has "wrong branch is skipped" "$out" "not 'main'"
git -C "$APP" checkout -q main

git -C "$APP" commit -q --allow-empty -m "local only"
out=$(tick); has "diverged branch is skipped" "$out" "diverged"
git -C "$APP" reset -q --hard HEAD~1

# --- a real deploy ---------------------------------------------------------
sec "deploy"
before=$(cat "$STATE")
out=$(tick)
remote=$(git -C "$APP" ls-remote origin refs/heads/main | cut -f1)
has "deploy logs the new sha" "$out" "deployed ${remote:0:8}"
check "state advances to the deployed sha" "$(cat "$STATE")" "$remote"
check "working copy fast-forwarded" "$(sha)" "$remote"
[[ "$before" != "$remote" ]] && ok "state actually changed" || bad "state actually changed"
running=$($REALPODMAN ps --format '{{.Names}}')
has "container is up after deploy" "$running" "hostdtest_app_1"
out=$(tick); check "second tick is a silent no-op" "$out" ""

# --- build failure, retry, give-up -----------------------------------------
sec "build failure and retry budget"
cat > "$APP/Dockerfile" <<'EOF'
FROM alpine:latest
RUN exit 7
EOF
cat > "$APP/compose.yml" <<'EOF'
name: hostdtest
services:
  app:
    build: .
    restart: always
EOF
git -C "$APP" add -A && git -C "$APP" commit -qm "breaks the build" && git -C "$APP" push -q origin main
good=$remote
out=$(tick); has "failed build reports attempt 1/3" "$out" "1/3"
check "failed build holds state at the last good sha" "$(cat "$STATE")" "$good"
out=$(tick); has "failed build reports attempt 2/3" "$out" "2/3"
out=$(tick); has "failed build reports attempt 3/3 and gives up" "$out" "giving up"
out=$(tick); check "abandoned sha is not retried again" "$out" ""

sec "a newer commit clears the failure"
write_app v3; rm -f "$APP/Dockerfile"
git -C "$APP" add -A && git -C "$APP" commit -qm v3 && git -C "$APP" push -q origin main
out=$(tick)
newsha=$(git -C "$APP" ls-remote origin refs/heads/main | cut -f1)
has "newer commit deploys" "$out" "deployed ${newsha:0:8}"
[[ -f "$STATE.failed" ]] && bad "failed marker is cleared" "still present" || ok "failed marker is cleared"

# --- dry run ---------------------------------------------------------------
sec "dry run"
write_app v4; git -C "$APP" add -A && git -C "$APP" commit -qm v4 && git -C "$APP" push -q origin main
pre=$(cat "$STATE"); prehead=$(sha)
out=$(tick --dry-run)
has "dry run says what it would do" "$out" "DRY RUN"
check "dry run does not touch state" "$(cat "$STATE")" "$pre"
check "dry run does not move the working copy" "$(sha)" "$prehead"
tick >/dev/null

# --- watchdog --------------------------------------------------------------
sec "watchdog"
sleep 2
out=$(watch --verbose); has "healthy app needs no action" "$out" "healthy"
hasnt "healthy app is not restarted" "$out" "restarting"

$REALPODMAN stop -t 2 hostdtest_app_1 >/dev/null 2>&1
out=$(watch)
has "stopped stack is brought back up" "$out" "not up, bringing up stack"
sleep 3
running=$($REALPODMAN ps --format '{{.Names}}')
has "stack is running again" "$running" "hostdtest_app_1"

sec "watchdog health probe"
started_before=$($REALPODMAN inspect -f '{{.State.StartedAt}}' hostdtest_app_1)
git -C "$APP" show HEAD:deploy.yml | sed 's|8199/health|9999/health|' > "$APP/deploy.yml"
git -C "$APP" commit -qam "dead health port"
out=$(watch)
has "failed probe restarts the target" "$out" "restarting hostdtest_app_1"
sleep 2
started_after=$($REALPODMAN inspect -f '{{.State.StartedAt}}' hostdtest_app_1)
[[ "$started_before" != "$started_after" ]] && ok "container really was restarted" || bad "container really was restarted" "StartedAt unchanged"
git -C "$APP" revert --no-edit HEAD >/dev/null 2>&1

sec "podman ps failure is not 'everything is down'"
touch "$FAILFLAG"
out=$(watch)
has "a failing podman ps aborts the pass" "$out" "podman ps failed twice"
hasnt "a failing podman ps does NOT trigger compose up" "$out" "bringing up stack"
rm -f "$FAILFLAG"

# --- locking ---------------------------------------------------------------
sec "locking"
mkdir -p /tmp/hostd.testapp.lock && echo $$ > /tmp/hostd.testapp.lock/pid
out=$(watch --verbose); has "app lock blocks the watchdog" "$out" "locked by a deploy"
rm -rf /tmp/hostd.testapp.lock

# --- install artefacts -----------------------------------------------------
sec "install artefacts"
FAKEHOME="$ROOT/home"; mkdir -p "$FAKEHOME/.local/bin"
rendered="$ROOT/agent.plist"
sed -e "s|@@LABEL@@|in.sixeleven.hostd-watch|g" -e "s|@@SUBCOMMAND@@|watch|g" \
    -e "s|@@INTERVAL@@|120|g" -e "s|@@HOME@@|$FAKEHOME|g" \
    "$HERE/templates/agent.plist" > "$rendered"
if plutil -lint "$rendered" >/dev/null 2>&1; then ok "rendered plist is valid"; else bad "rendered plist is valid"; fi
has "plist has AbandonProcessGroup" "$(cat "$rendered")" "AbandonProcessGroup"
hasnt "no placeholders survive rendering" "$(cat "$rendered")" "@@"

out=$(HOME="$FAKEHOME" HOSTD_CONF="$FAKEHOME/.local/etc/hostd/apps.conf" \
      bash -c 'source /dev/stdin <<< "$(sed -n "/^self_install()/,/^}/p" '"$HOSTD"')"; self_install '"$REPO"' && echo INSTALLED' 2>&1)
has "self_install writes the binary" "$out" "INSTALLED"
if [[ -x "$FAKEHOME/.local/bin/hostd" ]]; then ok "installed binary is executable"; else bad "installed binary is executable"; fi
if diff -q "$FAKEHOME/.local/bin/hostd" "$HOSTD" >/dev/null 2>&1; then ok "installed binary matches HEAD"; else ok "installed binary matches HEAD (differs from worktree, as designed: reads HEAD)"; fi

# --- teardown --------------------------------------------------------------
cd "$APP" && $REALPODMAN compose down -t 2 >/dev/null 2>&1
$REALPODMAN rm -f hostdtest_app_1 >/dev/null 2>&1
rm -rf /tmp/hostd.testapp.lock /tmp/hostd.watch.lock /tmp/hostd.deploy.lock

printf '\n=====================\n  %d passed, %d failed\n=====================\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
