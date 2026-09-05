#!/bin/bash
# One-shot cutover from the three legacy launchd agents to hostd, including the
# repository rename. Run it after all three PRs are merged and pulled.
#
#   ./framework/cutover.sh              # do it
#   ./framework/cutover.sh --dry-run    # print every action, change nothing
#   ./framework/cutover.sh --skip-rename
#   ./framework/cutover.sh --from install    # resume after a failed phase
#   ./framework/cutover.sh --rollback        # put the old agents back
#
# Phases: preflight, stop, install, verify, rename, docs.
#
# Preflight refuses to touch anything unless all three repos are merged, clean
# and on their tracked branch. Everything removed is backed up first, and
# --rollback restores it.
set -euo pipefail

# Step 5 renames the directory this script lives in. A same-filesystem rename
# would not actually invalidate our open fd, but relying on that is a poor
# thing to discover at 2am, so re-exec from a copy outside the tree.
if [[ "${HOSTD_CUTOVER_RELOCATED:-}" != 1 ]]; then
    _tmp=$(mktemp -t hostd-cutover) || exit 1
    cat "$0" > "$_tmp"; chmod +x "$_tmp"
    export HOSTD_CUTOVER_RELOCATED=1
    export HOSTD_CUTOVER_ORIGIN="$(cd "$(dirname "$0")/.." && pwd)"
    exec "$_tmp" "$@"
fi

REPO="${HOSTD_CUTOVER_ORIGIN:?}"
PODMAN=/opt/homebrew/bin/podman
AGENTS="$HOME/Library/LaunchAgents"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$HOME/.local/state/hostd-cutover/$STAMP"
OLD_AGENTS="odyssey backupd deployd"
NEW_AGENTS="hostd-watch hostd-deploy"
NEW_NAME=hostd
DRY=0; SKIP_RENAME=0; FROM=preflight; ROLLBACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --skip-rename) SKIP_RENAME=1; shift ;;
        --from) FROM="${2:?--from needs a phase}"; shift 2 ;;
        --rollback) ROLLBACK=1; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown flag $1" >&2; exit 2 ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s=== %s%s\n' "$YEL" "$*" "$OFF"; }
ok()   { printf '  %sok%s   %s\n' "$GRN" "$OFF" "$*"; }
info() { printf '  %s..%s   %s\n' "$DIM" "$OFF" "$*"; }
die()  { printf '\n%sFAILED:%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
run()  { if (( DRY )); then printf '  %s$ %s%s\n' "$DIM" "$*" "$OFF"; else eval "$@"; fi; }

phase_at_or_after() {  # ordered phase gate for --from
    local want="$1" order="preflight stop install verify rename docs" seen=0 p
    for p in $order; do
        [[ "$p" == "$FROM" ]] && seen=1
        [[ "$p" == "$want" ]] && { (( seen )) && return 0 || return 1; }
    done
    return 1
}

# --------------------------------------------------------------- rollback ---
if (( ROLLBACK )); then
    head_ "rollback"
    # --from install creates a fresh empty timestamp dir, so pick the newest
    # backup that actually holds agents rather than merely the newest dir.
    last=""
    for d in $(ls -1d "$HOME/.local/state/hostd-cutover"/*/ 2>/dev/null); do
        if compgen -G "${d}LaunchAgents/*.plist" >/dev/null 2>&1; then last="${d%/}"; fi
    done
    [[ -n "$last" ]] || die "no cutover backup containing agents was found"
    say "restoring from $last"
    for a in $NEW_AGENTS; do
        run "launchctl bootout 'gui/$UID/in.sixeleven.$a' 2>/dev/null || true"
        run "rm -f '$AGENTS/in.sixeleven.$a.plist'"
    done
    for f in "$last"/LaunchAgents/*.plist; do
        [[ -e "$f" ]] || continue
        b=$(basename "$f")
        run "cp '$f' '$AGENTS/$b'"
        run "launchctl bootstrap 'gui/$UID' '$AGENTS/$b'"
        ok "restored $b"
    done
    for f in "$last"/bin/*; do
        [[ -e "$f" ]] || continue
        run "cp '$f' '$HOME/.local/bin/$(basename "$f")' && chmod +x '$HOME/.local/bin/$(basename "$f")'"
    done
    if [[ -e "$last/deployd.conf" ]]; then
        run "cp '$last/deployd.conf' '$HOME/.local/etc/deployd.conf'"
    fi
    ok "old agents restored. The hostd state dir was left alone."
    exit 0
fi

ROLLBACK_CMD="$REPO/framework/cutover.sh --rollback"
say "hostd cutover  ${DIM}(backup: $BACKUP)${OFF}"
(( DRY )) && say "${YEL}DRY RUN: nothing will change${OFF}"

# -------------------------------------------------------------- preflight ---
CONTAINERS_BEFORE=""
if phase_at_or_after preflight; then
head_ "1/6 preflight"

command -v yq >/dev/null || die "yq is not installed. Run: brew install yq"
ok "yq $(yq --version 2>&1 | awk '{print $NF}')"
[[ -x "$REPO/framework/hostd" ]] || die "$REPO/framework/hostd not found. Is the backupd PR merged and pulled?"
ok "framework/hostd present"
"$PODMAN" ps >/dev/null 2>&1 || die "podman socket is down. Start it, then re-run."
ok "podman socket is up"

for l in /tmp/hostd.*.lock /tmp/in.sixeleven.*.lock; do
    [[ -e "$l" ]] || continue
    p=$(cat "$l/pid" 2>/dev/null || true)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
        die "$l is held by a live pid $p (a deploy or watchdog is mid-flight). Wait and re-run."
    fi
done
ok "no live locks"

REG="$REPO/framework/apps.conf"
[[ -f "$REG" ]] || die "no registry at $REG"
APPS=$(grep -v '^[[:space:]]*#' "$REG" | grep -v '^[[:space:]]*$')
[[ -n "$APPS" ]] || die "registry is empty"

while read -r path; do
    [[ -n "$path" ]] || continue
    [[ -d "$path" ]] || die "$path does not exist"
    name=$(git -C "$path" show HEAD:deploy.yml 2>/dev/null | yq -r '.name // ""') \
        || die "$path: cannot read deploy.yml at HEAD"
    [[ -n "$name" ]] || die "$path: deploy.yml at HEAD has no name. Is its PR merged and pulled?"
    branch=$(git -C "$path" show HEAD:deploy.yml | yq -r '.branch // "main"')
    cur=$(git -C "$path" rev-parse --abbrev-ref HEAD)
    [[ "$cur" == "$branch" ]] \
        || die "$name is on '$cur', not '$branch'. Merge the PR, then: git -C $path checkout $branch && git pull"
    [[ -z "$(git -C "$path" status --porcelain)" ]] \
        || die "$name has a dirty working tree at $path. Commit or stash, then re-run."
    git -C "$path" fetch -q origin "$branch" 2>/dev/null || die "$name: cannot reach origin"
    local_sha=$(git -C "$path" rev-parse HEAD)
    remote_sha=$(git -C "$path" rev-parse "origin/$branch")
    [[ "$local_sha" == "$remote_sha" ]] \
        || die "$name is not level with origin/$branch. Run: git -C $path pull --ff-only"
    ok "$(printf '%-10s %s @ %s, clean and level with origin' "$name" "$branch" "${local_sha:0:8}")"
done <<< "$APPS"

CONTAINERS_BEFORE=$("$PODMAN" ps --format '{{.Names}}' | sort)
info "running now: $(tr '\n' ' ' <<< "$CONTAINERS_BEFORE")"
echo "$CONTAINERS_BEFORE" > /tmp/hostd-cutover-containers-before
fi

# ------------------------------------------------------------------- stop ---
if phase_at_or_after stop; then
head_ "2/6 stop the old agents"
run "mkdir -p '$BACKUP/LaunchAgents' '$BACKUP/bin'"
for a in $OLD_AGENTS; do
    p="$AGENTS/in.sixeleven.$a.plist"
    if [[ -e "$p" ]]; then run "cp '$p' '$BACKUP/LaunchAgents/'"; fi
done
for b in odyssey-start backupd-start deployd; do
    if [[ -e "$HOME/.local/bin/$b" ]]; then run "cp '$HOME/.local/bin/$b' '$BACKUP/bin/'"; fi
done
if [[ -e "$HOME/.local/etc/deployd.conf" ]]; then
    run "cp '$HOME/.local/etc/deployd.conf' '$BACKUP/deployd.conf'"
fi
ok "backed up to $BACKUP"

for a in $OLD_AGENTS; do
    run "launchctl bootout 'gui/$UID/in.sixeleven.$a' 2>/dev/null || true"
    run "rm -f '$AGENTS/in.sixeleven.$a.plist'"
    ok "stopped in.sixeleven.$a"
done
run "rm -f '$HOME/.local/bin/odyssey-start' '$HOME/.local/bin/backupd-start' '$HOME/.local/bin/deployd'"
run "rm -f '$HOME/.local/etc/deployd.conf'"
ok "removed the old binaries and registry"
say "  ${DIM}containers keep running; nothing supervises them for the next few seconds${OFF}"
fi

# ---------------------------------------------------------------- install ---
if phase_at_or_after install; then
head_ "3/6 seed, then install"
# Seed BEFORE install. The agents carry RunAtLoad=true, so `hostd install`
# bootstraps them and the deploy agent fires immediately. With no state it
# would treat every app as never-deployed and rebuild all three from scratch,
# including excalidraw's multi-minute vite build. Seeding first makes that
# first tick a no-op. The registry is not installed yet, so point at the
# repo's copy; state lands in ~/.local/state/hostd either way.
run "HOSTD_CONF='$REPO/framework/apps.conf' '$REPO/framework/hostd' seed"
ok "seeded: the first tick will be a no-op, not a rebuild"

run "'$REPO/framework/hostd' install"
ok "installed the binary, the registry and both agents"

run "rm -rf '$HOME/.local/state/deployd'"
ok "removed the stale deployd state"
fi

# ----------------------------------------------------------------- verify ---
if phase_at_or_after verify; then
head_ "4/6 verify"
if (( DRY )); then
    info "would kickstart both agents and compare container sets"
else
    for a in $NEW_AGENTS; do
        launchctl kickstart -k "gui/$UID/in.sixeleven.$a" 2>/dev/null || true
        ok "kickstarted in.sixeleven.$a"
    done
    info "waiting 20s for both passes to complete"
    sleep 20

    # Capture, then match. `launchctl list | grep -q` under pipefail reports
    # 141: grep exits on the match and launchctl dies of SIGPIPE writing the
    # remaining 500-odd jobs. This exact bug read as "not loaded" on a real
    # run. It is the same mistake the old watchdogs made against `podman ps`.
    loaded=$(launchctl list 2>/dev/null || true)
    for a in $NEW_AGENTS; do
        grep -q "in.sixeleven.$a" <<<"$loaded" \
            || die "in.sixeleven.$a is not loaded. Check ~/Library/Logs/in.sixeleven.$a-error.log"
        # Loaded is not the same as working. A non-zero last exit status means
        # the agent ran and failed, which is how the bad subcommand hid.
        st=$(awk -v a="in.sixeleven.$a" '$3==a {print $2}' <<<"$loaded")
        [[ "$st" == "0" || "$st" == "-" ]] \
            || die "in.sixeleven.$a last exited $st. See ~/Library/Logs/in.sixeleven.$a-error.log"
    done
    ok "both agents are loaded and their last run exited clean"

    after=$("$PODMAN" ps --format '{{.Names}}' | sort)
    before=$(cat /tmp/hostd-cutover-containers-before 2>/dev/null || echo "$CONTAINERS_BEFORE")
    if [[ "$before" == "$after" ]]; then
        ok "container set unchanged, so nothing was needlessly rebuilt"
    else
        say "  ${YEL}note${OFF} container set changed:"
        diff <(echo "$before") <(echo "$after") | sed 's/^/       /' || true
    fi

    say ""
    "$REPO/framework/hostd" status | sed 's/^/  /'
    say ""
    bad=$("$REPO/framework/hostd" status | awk 'NR>1 && ($5=="DOWN" || $6=="FAIL")' || true)
    if [[ -n "$bad" ]]; then
        printf '%s\n' "$bad" >&2
        die "an app is DOWN or failing its health probe. Roll back with: $ROLLBACK_CMD"
    fi
    ok "every app is up, and every declared health endpoint answers"

    wl="$HOME/Library/Logs/in.sixeleven.hostd-watch.log"
    if [[ -s "$wl" ]] && grep -q "bringing up stack" "$wl"; then
        say "  ${YEL}note${OFF} the watch log already contains 'bringing up stack'."
        say "       Expected once if a stack was genuinely down. If it keeps"
        say "       recurring on a healthy box, the podman ps fix did not cure"
        say "       the old 37% misfire and it needs a real diagnosis."
    else
        ok "watch log is quiet, which is what healthy looks like"
    fi
fi
say ""
say "  ${DIM}Leave it 10 minutes, then: tail ~/Library/Logs/in.sixeleven.hostd-watch.log${OFF}"
say "  ${DIM}It should still be quiet.${OFF}"
fi

# ----------------------------------------------------------------- rename ---
if phase_at_or_after rename && (( ! SKIP_RENAME )); then
head_ "5/6 rename the repo to $NEW_NAME"
NEWREPO="$(dirname "$REPO")/$NEW_NAME"
if [[ "$(basename "$REPO")" == "$NEW_NAME" ]]; then
    ok "already renamed, nothing to do"
else
    slug=$(git -C "$REPO" remote get-url origin | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|')
    info "renaming $slug to ${slug%/*}/$NEW_NAME on GitHub"
    run "gh repo rename '$NEW_NAME' -R '$slug' --yes"
    ok "renamed on GitHub (the old URL redirects)"

    [[ -e "$NEWREPO" ]] && die "$NEWREPO already exists; move it aside first"
    run "mv '$REPO' '$NEWREPO'"
    run "git -C '$NEWREPO' remote set-url origin 'git@github.com:${slug%/*}/$NEW_NAME.git'"
    ok "moved to $NEWREPO and repointed origin"
    REPO="$NEWREPO"

    # The registry still names the old path. The app itself is still called
    # backupd, so its container and state file are untouched by this.
    run "sed -i '' 's|/$(basename "$(dirname "$NEWREPO")")/backupd|/$(basename "$(dirname "$NEWREPO")")/$NEW_NAME|' '$REPO/framework/apps.conf'"
    run "'$REPO/framework/hostd' sync"
    if (( ! DRY )) && [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
        run "git -C '$REPO' commit -qam 'chore: rename backupd to hostd'"
        run "git -C '$REPO' push -q origin HEAD"
        ok "committed and pushed the path change"
    fi
    run "'$REPO/framework/hostd' install"
    ok "reinstalled against the new path"

    if (( ! DRY )); then
        "$REPO/framework/hostd" status | sed 's/^/  /'
        if "$REPO/framework/hostd" status | grep -q "no manifest"; then
            die "an app no longer resolves. Check ~/.local/etc/hostd/apps.conf"
        fi
        ok "all apps still resolve after the rename"
    fi
fi
fi

# ------------------------------------------------------------------- docs ---
if phase_at_or_after docs && (( ! SKIP_RENAME )); then
head_ "6/6 fix the cross-repo doc reference"
ODY="$(dirname "$REPO")/odyssey"
if (( DRY )); then
    info "would branch odyssey, repoint ../backupd to ../$NEW_NAME, and open a PR"
elif grep -q '\.\./backupd' "$ODY/CLAUDE.md" 2>/dev/null; then
    br="chore/hostd-rename"
    git -C "$ODY" checkout -q -b "$br" 2>/dev/null || git -C "$ODY" checkout -q "$br"
    sed -i '' "s|\.\./backupd|../$NEW_NAME|g" "$ODY/CLAUDE.md"
    git -C "$ODY" commit -qam "chore: point at the renamed hostd repo"
    git -C "$ODY" push -q -u origin "$br"
    gh pr create --repo "$(git -C "$ODY" remote get-url origin | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|')" \
        --base main --head "$br" --title "chore: point at the renamed hostd repo" \
        --body "Follow-up to the hostd cutover. \`../backupd\` is now \`../$NEW_NAME\`." >/dev/null 2>&1 || true
    # Back to main immediately: hostd skips any app that is not on its tracked
    # branch, so leaving odyssey on a topic branch would silently pause deploys.
    git -C "$ODY" checkout -q main
    ok "opened a PR on odyssey and returned it to main"
else
    ok "no stale reference to fix"
fi
fi

head_ "done"
say "  Old agents backed up at $BACKUP"
say "  Roll back with: ${DIM}$REPO/framework/cutover.sh --rollback${OFF}"
say ""
say "  Still outstanding, unrelated: draw_cloudflared_1 is not running, so"
say "  draw.sixeleven.in is not served. Needs CLOUDFLARE_TUNNEL_TOKEN in"
say "  excalidraw's .env, the tunnel ingress, and the Cloudflare Access app."
