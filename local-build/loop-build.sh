#!/bin/bash
#
# loop-build.sh - build Loop and upload it to TestFlight entirely on this Mac.
#
# Uses LoopKit's own fastlane setup (the same lanes the GitHub "Browser Build"
# runs), with no GitHub Actions and no GitHub-hosted certificates:
#   * Source code is pulled from GitHub (LoopKit/LoopWorkspace by default).
#   * Signing certificates live in a local, encrypted fastlane match repo
#     ($LOOP_BUILD_HOME/match-secrets.git), not in a GitHub Match-Secrets repo.
#     Set MATCH_BACKUP_URL to mirror it to a private repo on your own git server.
#   * Apple is reached with an App Store Connect API key, so no Apple ID has
#     to be signed in to Xcode. Works over ssh and from launchd.
#
# First time on a new Mac: run install.sh (next to this script); it does all the setup.
#
# Commands:
#   check                       List what still needs doing before setup/build.
#   setup [--import-match URL]  One-time: create the local match repo (or copy an
#                               existing Match-Secrets repo), register identifiers,
#                               create or download certificates.
#   auto                        For the schedule: build only if LoopKit changed,
#                               your patches changed, or the last build is older
#                               than REBUILD_DAYS.
#   build                       Build and upload now.
#   status                      Show the last build and what is installed.
#   backup                      Mirror the certificate repo to MATCH_BACKUP_URL now.
#   nuke-certs                  Revoke all distribution certificates for the team
#                               and make new ones. Interactive only.
#
# Files (LOOP_BUILD_HOME defaults to ~/loop-build):
#   ~/.config/loop-build/config   Settings and secrets (chmod 600). See loop-build.conf.example.
#   $LOOP_BUILD_HOME/patches/     Optional customizations (or set PATCH_DIR): *.patch applies to
#                                 LoopWorkspace, <Submodule>/*.patch applies inside that submodule.
#   TOOLS_REPO (optional)         A clone of the repo that holds this script and your patches.
#                                 It is updated (git pull --ff-only) before each build.
#   $LOOP_BUILD_HOME/logs/        One log per run.
#   $LOOP_BUILD_HOME/artifacts/   IPA, dSYMs and build log of recent builds.
#
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

# Use this account's own home even if HOME says otherwise: macOS's sudo keeps the
# caller's HOME unless -i is used, so "sudo -u loopbuilder ..." would otherwise
# put loopbuilder's files in the caller's home.
_real_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
[ -n "$_real_home" ] || _real_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
if [ -n "$_real_home" ] && [ "$_real_home" != "${HOME:-}" ]; then
  echo "Note: HOME was ${HOME:-unset}; using $(id -un)'s home, $_real_home." >&2
  HOME="$_real_home"
  export HOME
fi

BASE="${LOOP_BUILD_HOME:-$HOME/loop-build}"
CONFIG="${LOOP_BUILD_CONFIG:-$HOME/.config/loop-build/config}"
SRC="$BASE/LoopWorkspace"
MATCH_REPO="$BASE/match-secrets.git"
BUNDLE_DIR="$BASE/bundle"
LOG_DIR="$BASE/logs"
STATE_DIR="$BASE/state"
PATCH_DIR="$BASE/patches"
ARTIFACT_DIR="$BASE/artifacts"
LOCK_DIR="$BASE/.lock"

# LoopKit's Matchfile builds the certificate repo URL from this owner name.
# Git is told to rewrite that URL to the local repo, so LoopKit's files stay untouched.
MATCH_OWNER="local-match"
MATCH_FAKE_URL="https://github.com/$MATCH_OWNER/Match-Secrets.git"

# launchd and ssh start with a minimal PATH. Use the private Ruby install.sh builds
# in $BASE/ruby; otherwise a Homebrew Ruby if there is one (macOS's own is too old).
for d in /usr/local/bin /opt/homebrew/bin /usr/local/opt/ruby/bin /opt/homebrew/opt/ruby/bin "$BASE/ruby/bin"; do
  if [ -d "$d" ]; then PATH="$d:$PATH"; fi
done
MIN_RUBY=3.2   # Bundler 4, pinned in LoopKit's Gemfile.lock, needs Ruby 3.2
export PATH
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

HAVE_LOCK=0
LOG_FILE=""

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# GNU stat first: BSD (macOS) stat rejects -c, while GNU stat accepts -f with another meaning.
file_mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }

# Secrets must belong to this user and be unreadable by anyone else.
check_private() {
  [ "$(file_owner "$1")" = "$(id -u)" ] || die "$1 must be owned by $(id -un)."
  case "$(file_mode "$1")" in
    *00) ;;
    *) die "$1 is readable by other users. Run: chmod 600 \"$1\"" ;;
  esac
}
is_private() {
  [ "$(file_owner "$1")" = "$(id -u)" ] || return 1
  case "$(file_mode "$1")" in *00) return 0 ;; *) return 1 ;; esac
}

# Hide any user:password@ in a URL before it is logged.
redact_url() { printf '%s' "$1" | sed -E 's#//[^/@]+@#//***@#'; }

load_config() {
  [ -f "$CONFIG" ] || die "No config at $CONFIG. Copy loop-build.conf.example there, fill it in, and chmod 600 it."
  check_private "$CONFIG"
  # shellcheck source=/dev/null
  . "$CONFIG"

  : "${TEAMID:?TEAMID is missing from $CONFIG}"
  : "${FASTLANE_KEY_ID:?FASTLANE_KEY_ID is missing from $CONFIG}"
  : "${FASTLANE_ISSUER_ID:?FASTLANE_ISSUER_ID is missing from $CONFIG}"
  : "${FASTLANE_KEY_PATH:?FASTLANE_KEY_PATH is missing from $CONFIG}"
  : "${MATCH_PASSWORD:?MATCH_PASSWORD is missing from $CONFIG}"
  [[ $TEAMID =~ ^[A-Z0-9]{10}$ ]] || die "TEAMID should be 10 capital letters/digits, got '$TEAMID'."

  FASTLANE_KEY_PATH="${FASTLANE_KEY_PATH/#\~/$HOME}"
  [ -f "$FASTLANE_KEY_PATH" ] || die "API key file not found: $FASTLANE_KEY_PATH"
  check_private "$FASTLANE_KEY_PATH"

  LOOP_REPO="${LOOP_REPO:-https://github.com/LoopKit/LoopWorkspace.git}"
  LOOP_BRANCH="${LOOP_BRANCH:-main}"
  XCODE_APP="${XCODE_APP:-}"
  PATCH_DIR="${PATCH_DIR/#\~/$HOME}"
  TOOLS_REPO="${TOOLS_REPO:-}"
  TOOLS_REPO="${TOOLS_REPO/#\~/$HOME}"
  REBUILD_DAYS="${REBUILD_DAYS:-30}"
  BUILD_ON_NEW_COMMITS="${BUILD_ON_NEW_COMMITS:-true}"
  KEEP_LOGS="${KEEP_LOGS:-30}"
  KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-3}"
  NOTIFY_CMD="${NOTIFY_CMD:-}"
  MATCH_BACKUP_URL="${MATCH_BACKUP_URL:-}"
  MATCH_BACKUP_SSH_KEY="${MATCH_BACKUP_SSH_KEY:-}"
  MATCH_BACKUP_SSH_KEY="${MATCH_BACKUP_SSH_KEY/#\~/$HOME}"
}

acquire_lock() {
  mkdir -p "$BASE"
  chmod 700 "$BASE"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "Another loop-build run (pid $pid) is in progress."
    fi
    log "Removing stale lock from pid ${pid:-unknown}."
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
  fi
  echo $$ > "$LOCK_DIR/pid"
  HAVE_LOCK=1
}

start_log() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S)-$1.log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "loop-build $1 started (log: $LOG_FILE)"
}

# Keep the newest $2 entries in directory $1.
prune() {
  local dir="$1" keep="$2"
  [ -d "$dir" ] || return 0
  # shellcheck disable=SC2012
  ls -1t "$dir" | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    rm -rf "${dir:?}/$f"
  done
}

notify() {
  [ -n "${NOTIFY_CMD:-}" ] || return 0
  LOOP_BUILD_STATUS="$1" LOOP_BUILD_MESSAGE="$2" LOOP_BUILD_LOG="$LOG_FILE" \
    /bin/sh -c "$NOTIFY_CMD" || log "Notification command failed."
}

on_exit() {
  local rc=$?
  set +e
  # fastlane's setup_ci leaves a temporary keychain holding the distribution
  # private key and makes it the default. Remove it after every run.
  if command -v security >/dev/null 2>&1; then
    security delete-keychain fastlane_tmp_keychain >/dev/null 2>&1
    if [ -f "$HOME/Library/Keychains/login.keychain-db" ]; then
      security default-keychain -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1
    fi
  fi
  if [ "$HAVE_LOCK" = 1 ]; then rm -rf "$LOCK_DIR"; fi
  if [ $rc -ne 0 ] && [ -n "$LOG_FILE" ]; then
    log "Failed (exit $rc). Log: $LOG_FILE"
    notify failure "Loop build failed. Log: $LOG_FILE"
  fi
  exit $rc
}
trap on_exit EXIT

version_ge() { # version_ge 2.39.5 2.31
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 0; fi
    if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 1; fi
  done
  return 0
}

check_tools() {
  command -v git >/dev/null || die "git not found. Install the Xcode command line tools."
  local gv
  gv="$(git --version | awk '{print $3}')"
  version_ge "$gv" 2.31 || die "git $gv is too old (need 2.31+)."
  command -v ruby >/dev/null || die "Ruby not found. Run install.sh to build a private Ruby in $BASE/ruby."
  command -v bundle >/dev/null || die "Bundler not found. Run install.sh to build a private Ruby in $BASE/ruby."
  local rv
  rv="$(ruby -e 'print RUBY_VERSION')"
  version_ge "$rv" "$MIN_RUBY" || die "Ruby $rv is too old (need $MIN_RUBY+). Run install.sh to build a private Ruby in $BASE/ruby."
}

# Bring the clone that holds this script and your patches up to date, so changes
# pushed there are used by the next scheduled build. Only fast-forwards; local
# edits or a network problem leave it as it is.
update_tools() {
  [ -n "$TOOLS_REPO" ] || return 0
  [ -d "$TOOLS_REPO/.git" ] || die "TOOLS_REPO is not a git checkout: $TOOLS_REPO"
  local before after
  before="$(git -C "$TOOLS_REPO" rev-parse HEAD)"
  log "Updating $TOOLS_REPO ($(git -C "$TOOLS_REPO" rev-parse --abbrev-ref HEAD))"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$TOOLS_REPO" pull -q --ff-only; then
    log "WARNING: Couldn't update $TOOLS_REPO (local changes, diverged branch or no network). Using it as it is."
    return 0
  fi
  after="$(git -C "$TOOLS_REPO" rev-parse HEAD)"
  [ "$before" != "$after" ] || return 0
  log "Updated to $(git -C "$TOOLS_REPO" log -1 --format='%h %s')"
  # This run keeps the version of the script it started with.
  if ! git -C "$TOOLS_REPO" diff --quiet "$before" "$after" -- local-build/loop-build.sh; then
    log "loop-build.sh itself changed; the new version is used from the next run."
  fi
}

# Fetch the latest source and undo anything a previous build changed
# (fastlane edits the Xcode project in place; patches modify files).
update_source() {
  if [ ! -d "$SRC/.git" ]; then
    log "Cloning $(redact_url "$LOOP_REPO") ($LOOP_BRANCH)"
    git clone --branch "$LOOP_BRANCH" --recurse-submodules "$LOOP_REPO" "$SRC"
  else
    log "Fetching $(redact_url "$LOOP_REPO") ($LOOP_BRANCH)"
    git -C "$SRC" remote set-url origin "$LOOP_REPO"
    git -C "$SRC" fetch --prune origin "$LOOP_BRANCH"
    git -C "$SRC" checkout -q -B "$LOOP_BRANCH" "origin/$LOOP_BRANCH"
    git -C "$SRC" reset -q --hard "origin/$LOOP_BRANCH"
  fi
  git -C "$SRC" submodule sync -q --recursive
  git -C "$SRC" submodule update -q --init --recursive --force
  git -C "$SRC" clean -ffdxq
  git -C "$SRC" submodule foreach -q --recursive 'git reset -q --hard && git clean -ffdxq'
  log "LoopWorkspace at $(git -C "$SRC" log -1 --format='%h %s (%cd)' --date=short)"
}

# Identifies what would be built: the LoopWorkspace commit plus your patches.
state_key() {
  local head patches=none
  head="$(git -C "$SRC" rev-parse HEAD)"
  if [ -d "$PATCH_DIR" ]; then
    patches="$(cd "$PATCH_DIR" && find . -type f -name '*.patch' -print0 | LC_ALL=C sort -z \
      | xargs -0 cat 2>/dev/null | shasum -a 256 | cut -c1-16)"
  fi
  echo "$head-$patches"
}

xcode_version() { # xcode_version /Applications/Xcode.app -> 27.1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null \
    || "$1/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | awk 'NR==1 {print $2}'
}

select_xcode() {
  local app="$XCODE_APP" want wantv havev
  want="$(grep -oE '/Applications/Xcode[^/"]*\.app' "$SRC/.github/workflows/build_loop.yml" 2>/dev/null | head -n 1 || true)"
  if [ -z "$app" ]; then
    app="$want"
    [ -n "$app" ] || die "Couldn't read which Xcode LoopKit uses. Set XCODE_APP in the config."
    log "LoopKit currently builds with $app"
  elif [ -n "$want" ] && [ -d "$app" ]; then
    wantv="$(printf '%s' "$want" | sed -E 's#.*/Xcode_?([0-9.]*)\.app#\1#')"
    havev="$(xcode_version "$app" || true)"
    # A newer Xcode in the same major series is fine; warn about older or other majors.
    if [ -n "$havev" ] && [ -n "$wantv" ] \
       && { [ "${havev%%.*}" != "${wantv%%.*}" ] || ! version_ge "$havev" "$wantv"; }; then
      log "WARNING: LoopKit now builds with Xcode $wantv, but XCODE_APP is Xcode $havev ($app). If the build fails, install Xcode $wantv (run install.sh again) or update XCODE_APP."
    fi
  fi
  [ -d "$app/Contents/Developer" ] || die "Xcode not found at $app. Install that version at that path (for example with 'xcodes'), or set XCODE_APP in the config."
  export DEVELOPER_DIR="$app/Contents/Developer"
  log "Using $(xcodebuild -version | tr '\n' ' ')"
  xcodebuild -showsdks 2>/dev/null | grep -q iphoneos \
    || die "The iOS platform isn't installed for this Xcode. Run: DEVELOPER_DIR=\"$DEVELOPER_DIR\" xcodebuild -downloadPlatform iOS"
}

apply_patches() {
  [ -d "$PATCH_DIR" ] || return 0
  local p d sub
  for p in "$PATCH_DIR"/*.patch; do
    [ -e "$p" ] || continue
    log "Applying patch $(basename "$p")"
    git -C "$SRC" apply --whitespace=fix -v "$p"
  done
  for d in "$PATCH_DIR"/*/; do
    [ -d "$d" ] || continue
    sub="$(basename "$d")"
    [ -d "$SRC/$sub" ] || die "patches/$sub/ doesn't match a folder in LoopWorkspace."
    for p in "$d"*.patch; do
      [ -e "$p" ] || continue
      log "Applying patch $sub/$(basename "$p")"
      git -C "$SRC" apply --directory="$sub" --whitespace=fix -v "$p"
    done
  done
}

bundle_install() {
  log "Installing fastlane and its gems"
  (cd "$SRC" && BUNDLE_PATH="$BUNDLE_DIR" bundle install --quiet)
}

# Run one of LoopKit's fastlane lanes with the environment GitHub Actions would provide.
run_lane() {
  log "fastlane $1"
  (
    cd "$SRC"
    export CI=true                       # makes the Fastfile use a temporary keychain
    export GITHUB_WORKSPACE="$SRC"
    export GITHUB_REPOSITORY_OWNER="$MATCH_OWNER"
    export GH_PAT=""
    export TEAMID FASTLANE_KEY_ID FASTLANE_ISSUER_ID MATCH_PASSWORD
    FASTLANE_KEY="$(cat "$FASTLANE_KEY_PATH")"
    export FASTLANE_KEY
    # Point fastlane match at the local certificate repo instead of GitHub.
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.file://$MATCH_REPO.insteadOf"
    export GIT_CONFIG_VALUE_0="$MATCH_FAKE_URL"
    # No fastlane usage reporting or update checks.
    export FASTLANE_OPT_OUT_USAGE=YES FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
    export BUNDLE_PATH="$BUNDLE_DIR"
    bundle exec fastlane "$1"
  )
}

# Make sure certificates and profiles exist; explain what to do if they can't be used.
ensure_certs() {
  if run_lane certs; then return 0; fi
  log "fastlane certs failed; checking the distribution certificate."
  rm -f "$SRC/fastlane/new_certificate_needed.txt"
  run_lane check_and_renew_certificates || true
  if [ "$(cat "$SRC/fastlane/new_certificate_needed.txt" 2>/dev/null)" = "true" ]; then
    die "Your distribution certificate is missing or expired. Run '$0 nuke-certs' interactively, then '$0 build'."
  fi
  die "fastlane certs failed. If Apple says you have too many certificates, revoke an unused distribution certificate at developer.apple.com, then run '$0 build'."
}

# Run git with the backup repo's credentials (MATCH_BACKUP_SSH_KEY), never prompting:
# under launchd a prompt would hang, so fail instead.
backup_git() {
  local ssh_cmd="${GIT_SSH_COMMAND:-ssh}"
  if [ -n "$MATCH_BACKUP_SSH_KEY" ]; then
    [ -f "$MATCH_BACKUP_SSH_KEY" ] || { log "WARNING: MATCH_BACKUP_SSH_KEY not found: $MATCH_BACKUP_SSH_KEY"; return 1; }
    ssh_cmd="ssh -i '$MATCH_BACKUP_SSH_KEY' -o IdentitiesOnly=yes"
  fi
  GIT_SSH_COMMAND="$ssh_cmd -o BatchMode=yes" GIT_TERMINAL_PROMPT=0 git "$@"
}

# Mirror the local certificate repo to MATCH_BACKUP_URL, if set. That URL is the
# only place this script ever pushes to. Returns non-zero if the push fails.
backup_match() {
  [ -n "$MATCH_BACKUP_URL" ] || return 0
  [ -d "$MATCH_REPO" ] || return 0
  local shown
  shown="$(redact_url "$MATCH_BACKUP_URL")"
  case "$MATCH_BACKUP_URL" in
    *github.com*) log "Note: MATCH_BACKUP_URL points at GitHub; a repo on your own git server keeps certificates off GitHub." ;;
  esac
  log "Backing up the certificate repo to $shown"
  if backup_git -C "$MATCH_REPO" push -q --mirror "$MATCH_BACKUP_URL"; then
    mkdir -p "$STATE_DIR"
    date +%s > "$STATE_DIR/last_match_backup_epoch"
    return 0
  fi
  log "WARNING: Couldn't push the certificate repo to $shown."
  return 1
}

save_artifacts() {
  local dest
  dest="$ARTIFACT_DIR/$(date +%Y-%m-%d_%H%M%S)"
  mkdir -p "$dest"
  if [ -d "$SRC/artifacts" ]; then cp -R "$SRC/artifacts/." "$dest/"; fi
  if [ -e "$SRC/buildlog" ]; then cp -R "$SRC/buildlog" "$dest/"; fi
  prune "$ARTIFACT_DIR" "$KEEP_ARTIFACTS"
  log "Saved build files to $dest"
}

cmd_setup() {
  local import_url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --import-match) import_url="${2:?--import-match needs a URL}"; shift 2 ;;
      *) die "Unknown option for setup: $1" ;;
    esac
  done

  acquire_lock
  start_log setup
  load_config
  check_tools
  update_tools
  mkdir -p "$STATE_DIR" "$PATCH_DIR" "$ARTIFACT_DIR"

  if [ -d "$MATCH_REPO" ]; then
    log "Local certificate repo already exists: $MATCH_REPO"
  elif [ -n "$import_url" ]; then
    log "Copying existing certificates from $(redact_url "$import_url") (one time)"
    git clone -q --mirror "$import_url" "$MATCH_REPO"
    # Cut the link so nothing is ever pushed back to where it came from.
    git -C "$MATCH_REPO" remote remove origin
  else
    log "Creating local certificate repo: $MATCH_REPO"
    git init -q --bare --initial-branch=master "$MATCH_REPO"   # fastlane match uses "master"
  fi
  chmod -R go-rwx "$MATCH_REPO"

  update_source
  select_xcode
  bundle_install
  run_lane identifiers
  ensure_certs
  backup_match || die "Certificates are ready, but the backup to MATCH_BACKUP_URL failed. Fix the URL or its access, then run '$0 backup'."
  date +%s > "$STATE_DIR/setup_complete"
  log "Setup complete. Make the first build with: $0 build"
}

cmd_build() {
  local mode="$1"
  acquire_lock
  start_log "$mode"
  load_config
  check_tools
  update_tools
  prune "$LOG_DIR" "$KEEP_LOGS"
  [ -d "$MATCH_REPO" ] || die "No local certificate repo. Run '$0 setup' first."
  mkdir -p "$STATE_DIR"

  update_source
  local key last_key last_epoch now age_days reason
  key="$(state_key)"

  if [ "$mode" = auto ]; then
    last_key="$(cat "$STATE_DIR/last_success_key" 2>/dev/null || true)"
    last_epoch="$(cat "$STATE_DIR/last_success_epoch" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age_days=$(( (now - last_epoch) / 86400 ))
    if [ -z "$last_key" ]; then
      reason="no previous successful build"
    elif [ "$BUILD_ON_NEW_COMMITS" = true ] && [ "$key" != "$last_key" ]; then
      reason="LoopKit or your patches changed"
    elif [ "$age_days" -ge "$REBUILD_DAYS" ]; then
      reason="last build was $age_days days ago"
    else
      log "Nothing to do: no changes, last build $age_days days ago (rebuild after $REBUILD_DAYS)."
      exit 0
    fi
    log "Building because $reason."
  fi

  select_xcode
  apply_patches
  bundle_install
  ensure_certs
  # A failed backup shouldn't stop the build; report it and carry on.
  backup_match || notify warning "Loop build: backing up the certificate repo failed. Log: $LOG_FILE"
  run_lane build_loop
  save_artifacts
  run_lane release

  echo "$key" > "$STATE_DIR/last_success_key"
  date +%s > "$STATE_DIR/last_success_epoch"
  git -C "$SRC" log -1 --format='%h %s' > "$STATE_DIR/last_success_commit"
  log "Done. Loop was uploaded to TestFlight; it appears there after Apple finishes processing."
  notify success "Loop build uploaded to TestFlight ($(cat "$STATE_DIR/last_success_commit"))"
}

cmd_backup() {
  acquire_lock
  start_log backup
  load_config
  [ -n "$MATCH_BACKUP_URL" ] || die "MATCH_BACKUP_URL isn't set in $CONFIG."
  [ -d "$MATCH_REPO" ] || die "No local certificate repo. Run '$0 setup' first."
  backup_match || die "Backup failed."
  log "Backup complete."
}

# Report everything that still needs doing, without changing anything.
cmd_check() {
  local problems=0 v val app="" wf xb sdks
  ok()   { printf '  ok    %s\n' "$*"; }
  todo() { printf '  TODO  %s\n' "$*"; problems=$((problems + 1)); }
  note() { printf '  note  %s\n' "$*"; }

  echo "Settings: $CONFIG"
  if [ ! -f "$CONFIG" ]; then
    todo "No config yet. Run: mkdir -p ~/.config/loop-build && cp ~/loop-build-src/local-build/loop-build.conf.example \"$CONFIG\" && chmod 600 \"$CONFIG\""
  else
    if is_private "$CONFIG"; then ok "only you can read it"; else todo "Run: chmod 600 \"$CONFIG\""; fi
    # shellcheck source=/dev/null
    . "$CONFIG"
    for v in TEAMID FASTLANE_KEY_ID FASTLANE_ISSUER_ID FASTLANE_KEY_PATH MATCH_PASSWORD; do
      val="${!v:-}"
      case "$val" in
        ""|*XXXXXXXXXX*|*xxxxxxxx-*|change-me) todo "Fill in $v in the config." ;;
        *) ok "$v is set" ;;
      esac
    done
    if [ -n "${TEAMID:-}" ] && ! [[ ${TEAMID:-} =~ ^[A-Z0-9]{10}$ ]]; then
      todo "TEAMID should be 10 capital letters/digits (developer.apple.com > Account > Membership details)."
    fi
    FASTLANE_KEY_PATH="${FASTLANE_KEY_PATH:-}"
    FASTLANE_KEY_PATH="${FASTLANE_KEY_PATH/#\~/$HOME}"
    case "$FASTLANE_KEY_PATH" in
      ""|*XXXXXXXXXX*) ;;
      *) if [ ! -f "$FASTLANE_KEY_PATH" ]; then todo "API key file not found: $FASTLANE_KEY_PATH"
         elif is_private "$FASTLANE_KEY_PATH"; then ok "API key file found, only you can read it"
         else todo "Run: chmod 600 \"$FASTLANE_KEY_PATH\""; fi ;;
    esac
  fi
  XCODE_APP="${XCODE_APP:-}"
  TOOLS_REPO="${TOOLS_REPO:-}"; TOOLS_REPO="${TOOLS_REPO/#\~/$HOME}"
  PATCH_DIR="${PATCH_DIR/#\~/$HOME}"
  MATCH_BACKUP_URL="${MATCH_BACKUP_URL:-}"
  MATCH_BACKUP_SSH_KEY="${MATCH_BACKUP_SSH_KEY:-}"; MATCH_BACKUP_SSH_KEY="${MATCH_BACKUP_SSH_KEY/#\~/$HOME}"

  echo "Tools"
  if command -v git >/dev/null && version_ge "$(git --version | awk '{print $3}')" 2.31; then ok "git $(git --version | awk '{print $3}')"
  else todo "git 2.31 or newer is needed (it comes with Xcode)."; fi
  if command -v ruby >/dev/null && version_ge "$(ruby -e 'print RUBY_VERSION')" "$MIN_RUBY" && command -v bundle >/dev/null; then
    ok "Ruby $(ruby -e 'print RUBY_VERSION') at $(command -v ruby)"
  else
    todo "Ruby $MIN_RUBY or newer is needed. Run install.sh to build a private one in $BASE/ruby."
  fi

  echo "Xcode"
  if [ -n "$XCODE_APP" ]; then
    app="$XCODE_APP"
  else
    for wf in "$SRC/.github/workflows/build_loop.yml" "${TOOLS_REPO:-$HOME/loop-build-src}/.github/workflows/build_loop.yml"; do
      [ -f "$wf" ] || continue
      app="$(grep -oE '/Applications/Xcode[^/"]*\.app' "$wf" | head -n 1 || true)"
      [ -n "$app" ] && break
    done
  fi
  if [ -z "$app" ]; then
    todo "Can't tell which Xcode to use. Set XCODE_APP in the config (find yours with: ls -d /Applications/Xcode*.app)."
  elif [ ! -d "$app/Contents/Developer" ]; then
    todo "Xcode not found at $app. Install that version there, or set XCODE_APP in the config to the Xcode you have (ls -d /Applications/Xcode*.app)."
  else
    xb="$app/Contents/Developer/usr/bin/xcodebuild"
    ok "$app (Xcode $(xcode_version "$app" || true))"
    if "$xb" -license check >/dev/null 2>&1; then ok "license accepted"
    else todo "Accept the Xcode license: sudo \"$xb\" -license accept"; fi
    if "$xb" -checkFirstLaunchStatus >/dev/null 2>&1; then ok "first-launch setup done"
    else todo "Finish Xcode's first-launch setup: sudo \"$xb\" -runFirstLaunch"; fi
    sdks="$("$xb" -showsdks 2>/dev/null || true)"
    if printf '%s' "$sdks" | grep -q iphoneos; then ok "iOS platform installed"
    else todo "Install the iOS platform: \"$xb\" -downloadPlatform iOS"; fi
    if printf '%s' "$sdks" | grep -q watchos; then ok "watchOS platform installed"
    else todo "Install the watchOS platform (Loop has a Watch app): \"$xb\" -downloadPlatform watchOS"; fi
  fi

  echo "Script and patches"
  if [ -z "$TOOLS_REPO" ]; then
    note "TOOLS_REPO isn't set, so patches aren't pulled from your fork automatically."
  elif [ -f "$TOOLS_REPO/local-build/loop-build.sh" ]; then
    ok "$TOOLS_REPO (branch $(git -C "$TOOLS_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
  else
    todo "$TOOLS_REPO has no local-build/ folder. Clone the branch that has it: see local-build/README.md, step 2."
  fi
  if [ -d "$PATCH_DIR" ]; then
    ok "$(cd "$PATCH_DIR" && find . -type f -name '*.patch' | wc -l | tr -d ' ') patch(es) in $PATCH_DIR"
  else
    note "No patch folder at $PATCH_DIR; builds will be unmodified LoopKit code."
  fi

  echo "Certificates"
  if [ -f "$STATE_DIR/setup_complete" ]; then ok "setup done; certificate repo at $MATCH_REPO"
  elif [ -d "$MATCH_REPO" ]; then note "setup didn't finish last time; run it again."
  else note "No certificate repo yet; 'setup' creates it."; fi
  if [ -z "$MATCH_BACKUP_URL" ]; then
    note "MATCH_BACKUP_URL isn't set; nothing backs up your certificate repo."
  elif backup_git ls-remote "$MATCH_BACKUP_URL" >/dev/null 2>&1; then
    ok "backup repo reachable: $(redact_url "$MATCH_BACKUP_URL")"
  else
    todo "Can't reach the backup repo $(redact_url "$MATCH_BACKUP_URL"). Check the URL and key, and connect once by hand to accept the server's host key."
  fi

  echo
  if [ "$problems" -gt 0 ]; then
    echo "$problems thing(s) to do before building."
    return 1
  fi
  if [ -f "$STATE_DIR/setup_complete" ]; then
    echo "Ready. Build and upload with: $0 build"
  else
    echo "Ready for setup. Run: $0 setup"
  fi
}

fmt_epoch() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M'; }

cmd_status() {
  echo "Home:          $BASE"
  if [ -f "$STATE_DIR/last_success_epoch" ]; then
    echo "Last success:  $(fmt_epoch "$(cat "$STATE_DIR/last_success_epoch")")"
    echo "Built commit:  $(cat "$STATE_DIR/last_success_commit" 2>/dev/null || echo unknown)"
  else
    echo "Last success:  never"
  fi
  if [ -d "$SRC/.git" ]; then
    echo "Local source:  $(git -C "$SRC" log -1 --format='%h %s' 2>/dev/null)"
    echo "Needs Xcode:   $(grep -oE '/Applications/Xcode[^/"]*\.app' "$SRC/.github/workflows/build_loop.yml" 2>/dev/null | head -n 1 || echo unknown)"
  fi
  echo "Cert repo:     $([ -d "$MATCH_REPO" ] && echo "$MATCH_REPO" || echo "missing (run setup)")"
  if [ -f "$STATE_DIR/last_match_backup_epoch" ]; then
    echo "Cert backup:   $(fmt_epoch "$(cat "$STATE_DIR/last_match_backup_epoch")")"
  else
    echo "Cert backup:   never (set MATCH_BACKUP_URL)"
  fi
  # shellcheck disable=SC2012
  echo "Latest log:    $(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -n 1 || echo none)"
}

cmd_nuke_certs() {
  [ -t 0 ] || die "nuke-certs must be run from an interactive terminal."
  acquire_lock
  start_log nuke-certs
  load_config
  check_tools
  echo
  echo "This revokes EVERY distribution certificate for team $TEAMID at Apple,"
  echo "including ones used by other apps or tools, then makes a new one."
  echo "Existing TestFlight builds keep working."
  printf 'Type NUKE to continue: '
  local answer
  read -r answer
  [ "$answer" = "NUKE" ] || die "Cancelled."
  update_source
  select_xcode
  bundle_install
  run_lane nuke_certs
  run_lane certs
  backup_match || die "New certificate created, but the backup to MATCH_BACKUP_URL failed. Fix it, then run '$0 backup'."
  log "New certificate created. Run '$0 build' to build with it."
}

usage() {
  sed -n '2,/^# Written for/p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
  setup)      shift; cmd_setup "$@" ;;
  auto)       cmd_build auto ;;
  build)      cmd_build build ;;
  status)     cmd_status ;;
  check)      cmd_check ;;
  backup)     cmd_backup ;;
  nuke-certs) cmd_nuke_certs ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
