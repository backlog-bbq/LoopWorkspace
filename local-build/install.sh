#!/bin/bash
#
# install.sh - set up this Mac to build Loop with loop-build.sh, then start the
# first build.
#
# With a separate Standard account for builds (recommended), run it twice:
#
#   ~/loop-build-src/local-build/install.sh --admin loopbuilder
#       From your own (administrator) account. Does only what needs an admin:
#       gets the shared Xcode in /Applications ready, clones the fork into
#       loopbuilder's home, hands over the API key file, and installs the weekly
#       schedule. Installs nothing in your account. Then it offers to continue as
#       loopbuilder, which runs:
#   sudo -iu loopbuilder /Users/loopbuilder/loop-build-src/local-build/install.sh
#       Everything else, inside loopbuilder's home. Use the full path: a "~" would
#       be expanded by your own shell and run your copy instead of loopbuilder's.
#
# With a single account, just run it as that account, without --admin.
#
# It walks through every step in README.md: links the script, gets Xcode ready,
# builds a private Ruby, asks for your Apple details, writes the settings file,
# sets up the certificate backup, runs 'loop-build.sh setup', installs the weekly
# schedule and starts the first build. Run it again any time: finished steps
# are detected and skipped, and your earlier answers are offered as defaults.
#
# Everything it installs goes in your home folder (~/loop-build, and Xcode in
# ~/Applications if it has to download one). It doesn't use Homebrew. sudo is
# used only for what Xcode itself requires (accepting its license, its
# first-launch setup) and, if you choose, the weekly schedule file in
# /Library/LaunchDaemons.
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

HERE="$(cd "$(dirname "$0")" && pwd -P)"          # local-build/ in your clone of the fork
TOOLS_DIR="$(cd "$HERE/.." && pwd -P)"           # the clone itself
BASE="${LOOP_BUILD_HOME:-$HOME/loop-build}"
CONFIG="${LOOP_BUILD_CONFIG:-$HOME/.config/loop-build/config}"
CONF_DIR="$(dirname "$CONFIG")"
LB="$BASE/loop-build.sh"
MATCH_REPO="$BASE/match-secrets.git"
PLIST_NAME="com.loopbuild.auto"
PLIST_DEST="/Library/LaunchDaemons/$PLIST_NAME.plist"
UPSTREAM_WORKFLOW="https://raw.githubusercontent.com/LoopKit/LoopWorkspace/main/.github/workflows/build_loop.yml"
RUBY_DIR="$BASE/ruby"                            # private Ruby, built by this script
TOOLS="$BASE/tools"                              # ruby-build and xcodes live here
# libyaml isn't on a Mac without Homebrew, and Ruby needs it for YAML (Bundler won't run without it).
LIBYAML_URL="https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz#c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"
XCODES_URL="https://github.com/XcodesOrg/xcodes/releases/latest/download/xcodes.zip"
MIN_RUBY=3.2                                     # Bundler 4, which LoopKit's Gemfile.lock pins, needs 3.2
XCODE_APP=""                                     # set by xcode_step (or from the settings file)

STEP=0
step() { STEP=$((STEP + 1)); printf '\n\033[1m%s. %s\033[0m\n' "$STEP" "$*"; }
info() { printf '   %s\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ask VAR "Question" [default]
ask() {
  local _var="$1" _q="$2" _def="${3:-}" _ans
  if [ -n "$_def" ]; then printf '   %s [%s]: ' "$_q" "$_def"; else printf '   %s: ' "$_q"; fi
  IFS= read -r _ans || die "No input."
  printf -v "$_var" '%s' "${_ans:-$_def}"
}
# ask_secret VAR "Question"   (not echoed)
ask_secret() {
  local _ans
  printf '   %s: ' "$2"
  IFS= read -rs _ans || die "No input."
  echo
  printf -v "$1" '%s' "$_ans"
}
# yesno "Question" y|n
yesno() {
  local ans hint="y/N"
  [ "$2" = y ] && hint="Y/n"
  while :; do
    printf '   %s [%s]: ' "$1" "$hint"
    IFS= read -r ans || die "No input."
    case "${ans:-$2}" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}
can_admin() { id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; }
admin_hint() {
  printf 'This needs your administrator account. From it, run (in your clone of the fork):\n    ~/loop-build-src/local-build/install.sh --admin %s\nthen run this again as %s.' "$(whoami)" "$(whoami)"
}
# Run a command with sudo; if that fails, say exactly what an admin needs to run.
run_sudo() {
  if sudo "$@"; then return 0; fi
  local q="" a
  for a in "$@"; do q="$q '$a'"; done
  die "That step needs an admin. From an admin account, run:
    sudo$q
then run this script again."
}
pause() { printf '   %s Press Return when done. ' "$*"; IFS= read -r _ || true; }

ALL_APPS="loop caregiver follow xdrip"
app_label() { # app_label APP -> "Loop|com.TEAMID.loopkit.Loop"
  case "$1" in
    loop)      echo "Loop|com.$TEAMID.loopkit.Loop" ;;
    caregiver) echo "LoopCaregiver|com.$TEAMID.loopkit.LoopCaregiver" ;;
    follow)    echo "LoopFollow|com.$TEAMID.LoopFollow" ;;
    xdrip)     echo "xDrip4iOS|com.$TEAMID.xdripswift" ;;
  esac
}
# Has 'loop-build.sh setup' registered this app? (Older setups kept Loop's state in state/.)
app_set_up() {
  [ -f "$BASE/state/$1/identifiers_done" ] && return 0
  [ "$1" = loop ] && [ ! -d "$BASE/state/loop" ] && [ -f "$BASE/state/setup_complete" ]
}

file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }

version_ge() { # version_ge 3.3.6 3.0
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 0; fi
    if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 1; fi
  done
  return 0
}

xcode_version() { # xcode_version /Applications/Xcode.app -> 27.1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null \
    || "$1/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | awk 'NR==1 {print $2}'
}

# Set KEY="value" in the config: replaces the first KEY= or #KEY= line, drops any
# later KEY= lines (they would override it), or appends if there's none.
set_conf() {
  local key="$1" val="$2" esc
  esc="$(printf '%s' "$val" | sed -e 's/[\\"$`]/\\&/g')"
  (
    umask 077
    KEY="$key" LINE="$key=\"$esc\"" awk '
      BEGIN { k = ENVIRON["KEY"]; line = ENVIRON["LINE"]; done = 0 }
      $0 ~ ("^#?" k "=") {
        if (!done) { print line; done = 1; next }
        if ($0 ~ ("^" k "=")) next
      }
      { print }
      END { if (!done) print line }' "$CONFIG" > "$CONFIG.tmp"
  )
  mv "$CONFIG.tmp" "$CONFIG"
}

# Run git against the backup repo the way loop-build.sh does, but accept the
# server's host key the first time (it's remembered for the unattended runs).
backup_git() {
  local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  if [ -n "$BACKUP_KEY" ]; then ssh_cmd="$ssh_cmd -i '$BACKUP_KEY' -o IdentitiesOnly=yes"; fi
  GIT_SSH_COMMAND="$ssh_cmd" GIT_TERMINAL_PROMPT=0 git "$@"
}


# Download the xcodes command-line tool into $TOOLS (no Homebrew).
get_xcodes() {
  [ -x "$TOOLS/xcodes" ] && return 0
  mkdir -p "$TOOLS"
  info "Downloading the xcodes tool into $TOOLS..."
  local zip="$TOOLS/xcodes.zip"
  if curl -fsSL -o "$zip" "$XCODES_URL" && unzip -oq "$zip" -d "$TOOLS" && [ -x "$TOOLS/xcodes" ]; then
    rm -f "$zip"
    return 0
  fi
  rm -f "$zip"
  warn "Couldn't download xcodes from $XCODES_URL."
  return 1
}

# xcode_step DOWNLOAD_DIR [OTHER_HOME]
# Find the Xcode LoopKit builds with (in /Applications, ~/Applications and
# OTHER_HOME/Applications), download it into DOWNLOAD_DIR if missing, and make
# sure its license, first-launch setup and iOS/watchOS platforms are done.
# Sets XCODE_APP. A Standard account can't do the admin parts; it's told how.
xcode_step() {
  local dl_dir="$1" other_home="${2:-}" want_app want chosen="" choice="" found match x sdks plat sdk
  want_app="$(curl -fsSL --max-time 20 "$UPSTREAM_WORKFLOW" 2>/dev/null | grep -oE '/Applications/Xcode[^/"]*\.app' | head -n 1 || true)"
  [ -n "$want_app" ] || want_app="$(grep -oE '/Applications/Xcode[^/"]*\.app' "$TOOLS_DIR/.github/workflows/build_loop.yml" 2>/dev/null | head -n 1 || true)"
  want="$(printf '%s' "$want_app" | sed -E 's#.*/Xcode_?([0-9.]*)\.app#\1#')"
  [ -n "$want" ] || die "Couldn't tell which Xcode LoopKit builds with. Check your network and run this again."
  info "LoopKit builds with Xcode $want."

  matches_want() { case "$1" in "$want"|"$want".*) return 0 ;; *) return 1 ;; esac; }
  # A newer Xcode in the same major series (27.2 when LoopKit names 27.1) builds Loop too.
  usable() { [ -n "$1" ] && [ "${1%%.*}" = "${want%%.*}" ] && version_ge "$1" "$want"; }
  list_xcodes() { # prints "path|version" for each Xcode found
    for x in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app ${other_home:+"$other_home"/Applications/Xcode*.app}; do
      [ -d "$x/Contents/Developer" ] || continue
      printf '%s|%s\n' "$x" "$(xcode_version "$x" || true)"
    done | awk '!seen[$0]++'
  }

  if [ -n "$XCODE_APP" ] && [ -d "$XCODE_APP/Contents/Developer" ] && usable "$(xcode_version "$XCODE_APP" || true)"; then
    chosen="$XCODE_APP"
  fi
  while [ -z "$chosen" ]; do
    found="$(list_xcodes)"
    # Prefer the exact version; otherwise the newest usable one.
    match="$(printf '%s\n' "$found" | while IFS='|' read -r p v; do if [ -n "$p" ] && matches_want "$v"; then echo "$p"; break; fi; done)"
    if [ -z "$match" ]; then
      match="$(printf '%s\n' "$found" | while IFS='|' read -r p v; do if usable "$v"; then echo "$v|$p"; fi; done \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d'|' -f2)"
      if [ -n "$match" ]; then
        info "Xcode $want isn't installed; using the newer $(xcode_version "$match" || true), which builds Loop too."
      fi
    fi
    if [ -n "$match" ]; then chosen="$match"; break; fi
    [ "$CAN_ADMIN" = 1 ] || die "Xcode $want (or a newer ${want%%.*}.x) isn't installed. $(admin_hint)"

    if [ -n "$found" ]; then
      info "None of the installed Xcodes is $want or a newer ${want%%.*}.x:"
      printf '%s\n' "$found" | awk -F'|' '{ printf "     %d) %s (Xcode %s)\n", NR, $1, $2 }'
    else
      info "No Xcode found."
    fi
    info "Options: i) download Xcode $want into $dl_dir with the 'xcodes' tool (asks for your Apple ID)"
    [ -n "$found" ] && info "         <number>) use one of the above anyway (the build may fail)"
    info "         r) I installed it another way; look again"
    ask choice "Choice" i
    case "$choice" in
      i|I)
        if get_xcodes; then
          mkdir -p "$dl_dir"
          "$TOOLS/xcodes" install "$want" --directory "$dl_dir" || warn "xcodes didn't finish."
        fi
        info "You can also download Xcode $want from developer.apple.com/download/all,"
        info "unpack it into $dl_dir and choose r."
        ;;
      r|R) ;;
      *[!0-9]*|"") warn "Not a choice." ;;
      *)
        chosen="$(printf '%s\n' "$found" | sed -n "${choice}p" | cut -d'|' -f1)"
        [ -n "$chosen" ] || warn "Not a choice."
        ;;
    esac
  done
  XCODE_APP="$chosen"
  XB="$XCODE_APP/Contents/Developer/usr/bin/xcodebuild"
  ok "Using $XCODE_APP (Xcode $(xcode_version "$XCODE_APP" || true))"

  # License and first launch are system-wide: once done, every account has them.
  if "$XB" -license check >/dev/null 2>&1; then
    ok "License accepted"
  else
    [ "$CAN_ADMIN" = 1 ] || die "The Xcode license hasn't been accepted. $(admin_hint)"
    info "Accepting the Xcode license (needs your password)..."
    run_sudo "$XB" -license accept
  fi
  if "$XB" -checkFirstLaunchStatus >/dev/null 2>&1; then
    ok "First-launch setup done"
  else
    [ "$CAN_ADMIN" = 1 ] || die "Xcode's first-launch setup hasn't run. $(admin_hint)"
    info "Running Xcode's first-launch setup (needs your password)..."
    run_sudo "$XB" -runFirstLaunch
  fi
  sdks="$("$XB" -showsdks 2>/dev/null || true)"
  for plat in iOS watchOS; do
    case "$plat" in iOS) sdk=iphoneos ;; *) sdk=watchos ;; esac   # names in -showsdks output
    if printf '%s' "$sdks" | grep -q -- "-sdk $sdk"; then
      ok "$plat platform installed"
    else
      info "Downloading the $plat platform (several GB; this takes a while)..."
      if ! "$XB" -downloadPlatform "$plat"; then
        [ "$CAN_ADMIN" = 1 ] && die "Downloading the $plat platform failed."
        die "Downloading the $plat platform failed. $(admin_hint)"
      fi
    fi
  done
}

# install_schedule USER HOME: the LaunchDaemon that runs 'loop-build.sh auto'
# weekly as USER. Needs an admin; a Standard account is told how.
install_schedule() {
  local u="$1" h="$2" tmp current
  tmp="$(mktemp)"
  sed -e "s#/Users/loopbuilder#$h#g" -e "s#loopbuilder#$u#g" "$HERE/$PLIST_NAME.plist" > "$tmp"
  if [ -f "$PLIST_DEST" ] && cmp -s "$tmp" "$PLIST_DEST"; then
    ok "Already installed: every Sunday at 3:17 AM as $u."
    rm -f "$tmp"
    return 0
  fi
  info "Builds automatically every Sunday at 3:17 AM, as $u, when LoopKit or the"
  info "patches change, and at least every 30 days. It runs while nobody is logged in,"
  info "which needs one system file: $PLIST_DEST"
  if [ "$CAN_ADMIN" != 1 ]; then
    info "$(admin_hint)"
    info "(Or build by hand with: $LB build)"
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$PLIST_DEST" ]; then
    current="$(grep -A1 '<key>UserName</key>' "$PLIST_DEST" | sed -n 's#.*<string>\(.*\)</string>.*#\1#p')"
    [ "$current" = "$u" ] || warn "It replaces the current schedule, which builds as ${current:-another user}."
  fi
  if yesno "Install the weekly schedule?" y; then
    sudo launchctl bootout "system/$PLIST_NAME" >/dev/null 2>&1 || true
    run_sudo install -o root -g wheel -m 644 "$tmp" "$PLIST_DEST"
    run_sudo launchctl bootstrap system "$PLIST_DEST"
    ok "Installed."
  else
    info "Skipped. Build by hand with: $LB build"
  fi
  rm -f "$tmp"
}

# The administrator's part of a two-account setup. Installs nothing in this account.
admin_mode() {
  local u="$1" uhome ugroup src url branch key
  can_admin || die "--admin has to run from an administrator account."
  [ "$u" != "$(whoami)" ] || die "That's this account. To build as yourself, run install.sh without --admin."
  id "$u" >/dev/null 2>&1 || die "There's no account named '$u'. Create a Standard account in System Settings >
Users & Groups (or: sudo sysadminctl -addUser $u -fullName 'Loop Builder' -password '<password>'),
then run this again."
  if id -Gn "$u" | tr ' ' '\n' | grep -qx admin; then
    warn "$u is an administrator. A Standard account is safer for builds."
  fi
  uhome="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$uhome" ] || uhome="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"
  if [ -z "$uhome" ] || ! sudo test -d "$uhome"; then
    die "$u has no home folder yet. Run: sudo createhomedir -c -u $u   then run this again."
  fi
  ugroup="$(id -gn "$u")"
  TOOLS="$(mktemp -d)"   # only for a downloaded xcodes; nothing goes in this account
  LB="$uhome/loop-build/loop-build.sh"

  echo "This prepares the Mac for $u to build Loop: only the parts that need an administrator."
  echo "Nothing is installed in your own account. It asks for your password for sudo."

  step "Xcode (shared by every account)"
  xcode_step /Applications "$uhome"

  step "$u's copy of the fork"
  src="$uhome/loop-build-src"
  if sudo test -f "$src/local-build/install.sh"; then
    ok "$src"
  else
    url="$(git -C "$TOOLS_DIR" remote get-url origin 2>/dev/null || echo "https://github.com/backlog-bbq/LoopWorkspace.git")"
    url="$(printf '%s' "$url" | sed -E 's#^git@github\.com:#https://github.com/#')"   # $u has no ssh key for GitHub
    branch="$(git -C "$TOOLS_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    (cd / && run_sudo -u "$u" -H git clone -q --single-branch -b "$branch" "$url" "$src")
    ok "Cloned $branch of $url into $src"
  fi

  step "App Store Connect API key for $u"
  key="$(for f in "$HOME"/Downloads/AuthKey_*.p8 "$HOME"/AuthKey_*.p8; do [ -f "$f" ] && echo "$f"; done | head -n 1 || true)"
  if [ -z "$key" ]; then
    info "No AuthKey_*.p8 in your Downloads. $u's setup will ask for it; to hand it over"
    info "from here instead, copy it into ~/Downloads and run this again."
  elif yesno "Give $(basename "$key") to $u? (moves it into $u's ~/.config/loop-build, readable only by $u)" y; then
    (cd / && run_sudo -u "$u" -H mkdir -p "$uhome/.config/loop-build")
    (cd / && run_sudo -u "$u" -H chmod 700 "$uhome/.config/loop-build")
    run_sudo install -o "$u" -g "$ugroup" -m 600 "$key" "$uhome/.config/loop-build/"
    rm -f "$key"
    ok "Moved to $uhome/.config/loop-build/$(basename "$key")"
  fi

  step "Weekly schedule for $u"
  install_schedule "$u" "$uhome"

  rm -rf "$TOOLS"
  step "Now $u's part"
  info "The rest runs as $u, inside $u's home: Ruby, settings, certificates, first build."
  if yesno "Continue as $u now?" y; then
    exec sudo -iu "$u" "$src/local-build/install.sh"
  fi
  info "Later, from this account, run:"
  info "  sudo -iu $u $src/local-build/install.sh"
  exit 0
}
# ---------------------------------------------------------------------------

[ -t 0 ] || die "Run this from an interactive terminal (ssh into the Mac and run it there)."
if [ "$(uname)" != Darwin ] && [ -z "${LOOP_INSTALL_SKIP_OS_CHECK:-}" ]; then
  die "This sets up a Mac; run it on the Mac mini."
fi
[ -f "$HERE/loop-build.sh" ] || die "loop-build.sh isn't next to this script ($HERE)."
[ "$(id -u)" != 0 ] || die "Run this as a normal user, not as root (it uses sudo when needed)."

CAN_ADMIN=0
if can_admin; then CAN_ADMIN=1; fi
build_user=""
case "${1:-}" in
  "") ;;
  --admin) admin_mode "${2:?Usage: install.sh --admin <build-account>}" ;;
  -h|--help) sed -n '2,/^# Written for/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown option: $1 (see install.sh --help)" ;;
esac

# This account's settings will point at the clone this script runs from, so it
# has to be this account's own clone, not someone else's.
if [ "$(file_owner "$HERE/install.sh")" != "$(id -u)" ]; then
  own="$HOME/loop-build-src/local-build/install.sh"
  if [ -f "$own" ]; then
    die "This copy of install.sh belongs to another account ($HERE).
Run $(whoami)'s own copy instead:
    $own
(From your admin account: sudo -iu $(whoami) $own )"
  fi
  die "This copy of install.sh belongs to another account ($HERE), and $(whoami) has no
copy of the fork yet. From your admin account, run its own copy with:
    ~/loop-build-src/local-build/install.sh --admin $(whoami)"
fi

if [ "$CAN_ADMIN" = 1 ]; then
  echo "$(whoami) is an administrator account. Builds can run here, or in a separate"
  echo "Standard account (safer: the signing keys and build tools live only there)."
  if ! yesno "Build Loop in this account ($(whoami))?" n; then
    ask build_user "Name of the build account" loopbuilder
    admin_mode "$build_user"
  fi
fi
echo "This sets up $(whoami) on $(hostname -s 2>/dev/null || hostname) to build Loop and upload it to TestFlight."
echo "Settings go in $CONFIG; builds happen in $BASE."

# Earlier answers become defaults.
TEAMID="" FASTLANE_KEY_ID="" FASTLANE_ISSUER_ID="" FASTLANE_KEY_PATH="" MATCH_PASSWORD=""
XCODE_APP="" MATCH_BACKUP_URL="" MATCH_BACKUP_SSH_KEY="" APPS=""
if [ -f "$CONFIG" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG"
  echo "Found your settings from last time; press Return to keep each value."
fi
FASTLANE_KEY_PATH="${FASTLANE_KEY_PATH/#\~/$HOME}"
MATCH_BACKUP_SSH_KEY="${MATCH_BACKUP_SSH_KEY/#\~/$HOME}"
case "$TEAMID$FASTLANE_KEY_ID" in *XXXXXXXXXX*) TEAMID="" FASTLANE_KEY_ID="" ;; esac
case "$FASTLANE_ISSUER_ID" in *xxxxxxxx*) FASTLANE_ISSUER_ID="" ;; esac
case "$FASTLANE_KEY_PATH" in *XXXXXXXXXX*) FASTLANE_KEY_PATH="" ;; esac
[ "$MATCH_PASSWORD" != change-me ] || MATCH_PASSWORD=""
IMPORT_URL=""

# ---------------------------------------------------------------------------
step "Link the build script"
mkdir -p "$BASE"
chmod 700 "$BASE"
if [ -e "$LB" ] && [ ! -L "$LB" ]; then
  mv "$LB" "$LB.old"
  warn "Moved an older copy to $LB.old"
fi
ln -sf "$HERE/loop-build.sh" "$LB"
ok "$LB -> $HERE/loop-build.sh"
if git -C "$TOOLS_DIR" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
  ok "Your fork's clone: $TOOLS_DIR (branch $(git -C "$TOOLS_DIR" rev-parse --abbrev-ref HEAD))"
else
  warn "$TOOLS_DIR isn't a git clone, so patches won't be pulled from your fork automatically."
fi

# ---------------------------------------------------------------------------
step "Xcode"
xcode_step "$HOME/Applications" ""

# ---------------------------------------------------------------------------
step "Ruby (fastlane needs Ruby $MIN_RUBY or newer)"
ruby_ok() { # ruby_ok /path/to/ruby
  [ -x "$1" ] && version_ge "$("$1" -e 'print RUBY_VERSION' 2>/dev/null || echo 0)" "$MIN_RUBY" \
    && "$1" -e 'require "psych"; require "openssl"' >/dev/null 2>&1
}
if ruby_ok "$RUBY_DIR/bin/ruby"; then
  ok "Private Ruby $("$RUBY_DIR/bin/ruby" -e 'print RUBY_VERSION') in $RUBY_DIR"
else
  info "Building a private Ruby in $RUBY_DIR with ruby-build. Nothing is installed"
  info "outside that folder. It compiles OpenSSL and Ruby, so it takes 10-20 minutes."
  mkdir -p "$TOOLS"
  if [ -d "$TOOLS/ruby-build/.git" ]; then
    git -C "$TOOLS/ruby-build" pull -q --ff-only 2>/dev/null || warn "Couldn't update ruby-build; using the copy there."
  else
    git clone -q --depth 1 https://github.com/rbenv/ruby-build.git "$TOOLS/ruby-build"
  fi
  # Newest Ruby 3.4 that ruby-build knows, with libyaml added in front.
  rver="$(cd "$TOOLS/ruby-build/share/ruby-build" && printf '%s\n' 3.4.* | grep -E '^3\.4\.[0-9]+$' | sort -t. -k3,3n | tail -n 1)"
  [ -n "$rver" ] || die "ruby-build doesn't list a Ruby 3.4 release."
  def="$TOOLS/loop-ruby-$rver"
  {
    echo "install_package \"yaml-0.2.5\" \"$LIBYAML_URL\""
    cat "$TOOLS/ruby-build/share/ruby-build/$rver"
  } > "$def"
  # The compiler comes from the Xcode chosen above; no command line tools install needed.
  DEVELOPER_DIR="$XCODE_APP/Contents/Developer" \
  RUBY_CONFIGURE_OPTS="--with-libyaml-dir=$RUBY_DIR --disable-install-doc" \
    "$TOOLS/ruby-build/bin/ruby-build" "$def" "$RUBY_DIR" \
    || die "Building Ruby failed; the lines above say why. Fix that and run this again."
  ruby_ok "$RUBY_DIR/bin/ruby" || die "Ruby was built but can't load YAML or OpenSSL support."
  ok "Private Ruby $("$RUBY_DIR/bin/ruby" -e 'print RUBY_VERSION') in $RUBY_DIR"
fi
PATH="$RUBY_DIR/bin:$PATH"
export PATH

# ---------------------------------------------------------------------------
step "Your Apple Developer team"
info "Team ID: developer.apple.com > Account > Membership details (10 characters)."
while :; do
  ask TEAMID "Team ID" "$TEAMID"
  TEAMID="$(printf '%s' "$TEAMID" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  [[ $TEAMID =~ ^[A-Z0-9]{10}$ ]] && break
  warn "That should be 10 letters and digits."
  TEAMID=""
done

# ---------------------------------------------------------------------------
step "Apps to build"
info "loop = Loop, caregiver = LoopCaregiver, follow = LoopFollow, xdrip = xDrip4iOS."
info "They all share one distribution certificate. You can change this later."
while :; do
  ask APPS "Apps, separated by spaces" "${APPS:-loop}"
  APPS="$(printf '%s' "$APPS" | tr '[:upper:],' '[:lower:] ' | tr -s ' ' | sed 's/^ //; s/ $//')"
  bad=""
  for a in $APPS; do case " $ALL_APPS " in *" $a "*) ;; *) bad="$bad $a" ;; esac; done
  [ -n "$APPS" ] && [ -z "$bad" ] && break
  warn "Unknown:${bad:- (none given)}. Choose from: $ALL_APPS"
  APPS=""
done
ok "Building: $APPS"

# ---------------------------------------------------------------------------
step "App Store Connect API key"
mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
find_keys() {
  local f
  for f in "$FASTLANE_KEY_PATH" "$CONF_DIR"/AuthKey_*.p8 "$HOME"/Downloads/AuthKey_*.p8 "$HOME"/AuthKey_*.p8; do
    if [ -n "$f" ] && [ -f "$f" ]; then echo "$f"; fi
  done | awk '!seen[$0]++'
}
key=""
while [ -z "$key" ]; do
  keys="$(find_keys)"
  if [ -n "$keys" ]; then
    first="$(printf '%s\n' "$keys" | head -n 1)"
    if [ "$(printf '%s\n' "$keys" | wc -l | tr -d ' ')" -gt 1 ]; then
      info "Found these keys:"
      printf '%s\n' "$keys" | sed 's/^/     /'
    fi
    ask key "Key file to use" "$first"
    key="${key/#\~/$HOME}"
    [ -f "$key" ] || { warn "No file at $key."; key=""; }
  else
    info "No .p8 key file found on this Mac. To make one:"
    info "  App Store Connect > Users and Access > Integrations > App Store Connect API >"
    info "  Team Keys > '+', any name, Access: Admin. Download the .p8 (only possible once)."
    info "Then copy it here from the computer you downloaded it on:"
    info "  scp ~/Downloads/AuthKey_*.p8 $(whoami)@$(hostname -s 2>/dev/null || hostname).local:${CONF_DIR#"$HOME"/}/"
    info "Or put it in your admin account's ~/Downloads and run install.sh --admin $(whoami) there."
    info "(Or type the path of a key file that's already on this Mac.)"
    ask key "Path to the .p8 file (Return to look again)" ""
    key="${key/#\~/$HOME}"
    [ -z "$key" ] || [ -f "$key" ] || { warn "No file at $key."; key=""; }
  fi
done
case "$key" in
  "$CONF_DIR"/*) ;;
  *)
    if yesno "Move $(basename "$key") into $CONF_DIR (recommended, it's a secret)?" y; then
      mv "$key" "$CONF_DIR/"
    else
      cp "$key" "$CONF_DIR/"
    fi
    key="$CONF_DIR/$(basename "$key")"
    ;;
esac
chmod 600 "$key"
FASTLANE_KEY_PATH="$key"
ok "Key file: $FASTLANE_KEY_PATH"

guess_id="$(basename "$key" | sed -nE 's/^AuthKey_([A-Z0-9]{10})\.p8$/\1/p')"
while :; do
  ask FASTLANE_KEY_ID "Key ID" "${FASTLANE_KEY_ID:-$guess_id}"
  [[ $FASTLANE_KEY_ID =~ ^[A-Z0-9]{10}$ ]] && break
  warn "That should be 10 letters and digits (the Key ID column in App Store Connect)."
  FASTLANE_KEY_ID="" guess_id=""
done
info "Issuer ID: shown above the list of keys in App Store Connect."
while :; do
  ask FASTLANE_ISSUER_ID "Issuer ID" "$FASTLANE_ISSUER_ID"
  [[ $FASTLANE_ISSUER_ID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && break
  warn "That should look like 69a6de7f-1234-47e3-e053-5b8c7c11a4d1."
  FASTLANE_ISSUER_ID=""
done

# ---------------------------------------------------------------------------
step "Certificate password"
if [ -d "$MATCH_REPO" ] && [ -n "$MATCH_PASSWORD" ]; then
  ok "Keeping the password of your existing certificate repo."
elif [ -d "$MATCH_REPO" ]; then
  info "You already have a certificate repo ($MATCH_REPO), so its password is needed."
  while [ -z "$MATCH_PASSWORD" ]; do ask_secret MATCH_PASSWORD "Its MATCH_PASSWORD (not shown)"; done
elif [ -n "$MATCH_PASSWORD" ]; then
  ok "Keeping the password from your settings."
else
  if [ ! -d "$MATCH_REPO" ] && yesno "Do you have a Match-Secrets repo from a Browser Build that you want to reuse?" n; then
    ask IMPORT_URL "Its git URL" ""
    ask_secret MATCH_PASSWORD "Its MATCH_PASSWORD (not shown)"
  else
    MATCH_PASSWORD="$(openssl rand -base64 30 | tr -d '\n')"
    info "This password encrypts your certificates. Save it in your password manager now;"
    info "without it the certificate repo and its backup can't be opened:"
    echo
    echo "     $MATCH_PASSWORD"
    echo
    pause "Saved it?"
  fi
fi

# ---------------------------------------------------------------------------
step "Certificate backup on your git server"
BACKUP_KEY="$MATCH_BACKUP_SSH_KEY"
backup_done=0
if [ -n "$MATCH_BACKUP_URL" ] && backup_git ls-remote "$MATCH_BACKUP_URL" >/dev/null 2>&1; then
  ok "Backup repo reachable: $MATCH_BACKUP_URL"
  yesno "Keep using it?" y && backup_done=1
fi
if [ "$backup_done" = 0 ] && [ -z "$MATCH_BACKUP_URL" ]; then
  info "Your distribution certificate will exist only on this Mac unless it's backed up."
  info "Create an EMPTY, PRIVATE repo for it on your git server (e.g. loop-match-backup)."
  info "Each backup replaces that repo's contents, so use it for nothing else."
fi
while [ "$backup_done" = 0 ]; do
  if [ -z "$MATCH_BACKUP_URL" ] && ! yesno "Set up the backup now?" y; then
    warn "Skipping the backup. Run this again to add it later."
    MATCH_BACKUP_URL="" BACKUP_KEY=""
    break
  fi
  info "Use the repo's ssh URL, e.g. ssh://git@forge.lan:2222/you/loop-match-backup.git"
  info "(A path to a bare repo on a mounted disk works too.)"
  ask MATCH_BACKUP_URL "Backup repo URL" "$MATCH_BACKUP_URL"
  [ -n "$MATCH_BACKUP_URL" ] || continue
  case "$MATCH_BACKUP_URL" in
    /*|file://*)
      BACKUP_KEY=""
      ;;
    http://*|https://*)
      BACKUP_KEY=""
      warn "With an https URL, git needs a stored token that works without you logged in."
      warn "An ssh URL with a deploy key is more reliable for the weekly runs."
      ;;
    *)
      [ -n "$BACKUP_KEY" ] || BACKUP_KEY="$HOME/.ssh/loop_match_backup"
      if [ ! -f "$BACKUP_KEY" ]; then
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -q -t ed25519 -N "" -C "loop-match-backup@$(hostname -s 2>/dev/null || hostname)" -f "$BACKUP_KEY"
        info "Made a key just for the backup: $BACKUP_KEY"
      fi
      info "Add this public key to the backup repo as a deploy key WITH WRITE ACCESS"
      info "(repo Settings > Deploy Keys on Gitea, Forgejo and GitLab):"
      echo
      sed 's/^/     /' "$BACKUP_KEY.pub"
      echo
      pause "Added it?"
      ;;
  esac
  info "Testing access..."
  if refs="$(backup_git ls-remote "$MATCH_BACKUP_URL" 2>&1)"; then
    ok "The backup repo is reachable."
    if [ -n "$refs" ] && [ ! -d "$MATCH_REPO" ]; then
      warn "That repo isn't empty. Backups will replace everything in it."
      yesno "Use it anyway?" n || { MATCH_BACKUP_URL=""; continue; }
    fi
    break
  fi
  warn "Couldn't reach it:"
  printf '%s\n' "$refs" | tail -n 3 | sed 's/^/       /'
  info "Check the URL and that the deploy key has write access."
  yesno "Try again?" y || { warn "Skipping the backup."; MATCH_BACKUP_URL="" BACKUP_KEY=""; break; }
done

# ---------------------------------------------------------------------------
step "Write the settings file"
if [ -f "$CONFIG" ]; then
  cp -p "$CONFIG" "$CONFIG.bak"
  info "Saved the previous settings as $CONFIG.bak"
else
  (umask 077; cp "$HERE/loop-build.conf.example" "$CONFIG")
fi
chmod 600 "$CONFIG"
set_conf TEAMID "$TEAMID"
set_conf FASTLANE_KEY_ID "$FASTLANE_KEY_ID"
set_conf FASTLANE_ISSUER_ID "$FASTLANE_ISSUER_ID"
set_conf FASTLANE_KEY_PATH "$FASTLANE_KEY_PATH"
set_conf MATCH_PASSWORD "$MATCH_PASSWORD"
set_conf TOOLS_REPO "$TOOLS_DIR"
set_conf PATCH_DIR "$HERE/patches"
set_conf XCODE_APP "$XCODE_APP"
set_conf APPS "$APPS"
set_conf MATCH_BACKUP_URL "$MATCH_BACKUP_URL"
set_conf MATCH_BACKUP_SSH_KEY "$BACKUP_KEY"
chmod 600 "$CONFIG"
ok "$CONFIG"

# ---------------------------------------------------------------------------
step "Check everything"
if ! "$LB" check; then
  die "Fix the items marked TODO above, then run this again."
fi

# ---------------------------------------------------------------------------
step "Register the apps with Apple and create certificates"
todo_apps=""
for a in $APPS; do app_set_up "$a" || todo_apps="$todo_apps $a"; done
todo_apps="${todo_apps# }"
if [ -f "$BASE/state/setup_complete" ] && [ -z "$todo_apps" ]; then
  ok "Already done."
else
  info "This downloads each app's code (Loop's alone is ~22 repos), installs fastlane,"
  info "registers the apps' identifiers and creates your distribution certificate."
  info "It takes a while."
  if [ -n "$IMPORT_URL" ]; then
    # shellcheck disable=SC2086
    "$LB" setup --import-match "$IMPORT_URL" ${todo_apps:-$APPS}
  else
    # shellcheck disable=SC2086
    "$LB" setup ${todo_apps:-$APPS}
  fi
fi

# ---------------------------------------------------------------------------
step "The apps in App Store Connect"
info "TestFlight uploads need an app in App Store Connect > Apps for each of these"
info "bundle IDs. One you've uploaded to TestFlight with this team before is there already."
for a in $APPS; do
  l="$(app_label "$a")"
  info "  ${l%%|*}: ${l#*|}"
done
if ! yesno "Are they all there?" y; then
  info "For each missing one: App Store Connect > Apps > '+' > New App. Platform iOS,"
  info "any name nobody else on the App Store uses, the bundle ID above, any SKU,"
  info "Full Access."
  pause "Created them?"
fi

# ---------------------------------------------------------------------------
step "Weekly schedule"
install_schedule "$(whoami)" "$HOME"

# ---------------------------------------------------------------------------
step "First build"
info "A build can take well over half an hour. It runs in the background, so closing"
info "this ssh session doesn't stop it, and keeps the Mac awake until it's done."
if yesno "Build and upload now ($APPS)?" y; then
  nohup caffeinate -i "$LB" build >/dev/null 2>&1 &
  pid=$! latest="" i=0
  # Wait for the build's own log to appear (logs are named ...-build.log).
  while [ $i -lt 15 ]; do
    sleep 1
    # shellcheck disable=SC2012
    latest="$(ls -t "$BASE"/logs/*-build.log 2>/dev/null | head -n 1 || true)"
    if [ -n "$latest" ] && [ "$latest" -nt "$CONFIG" ]; then break; fi
    latest=""
    kill -0 "$pid" 2>/dev/null || break
    i=$((i + 1))
  done
  if [ -z "$latest" ]; then
    die "The build didn't start. Run it by hand to see why: $LB build"
  fi
  ok "Started. Log: $latest"
  info "Each app ends with \"Done. <app> was uploaded to TestFlight\". After Apple processes"
  info "it, it shows up in the TestFlight app. '$LB status' shows how the last builds went."
  if [ -n "$latest" ] && yesno "Watch the log now? (Ctrl-C stops watching, not the build)" y; then
    exec tail -f "$latest"
  fi
else
  info "Start it later with: nohup caffeinate -i $LB build >/dev/null 2>&1 &"
  if [ -f "$PLIST_DEST" ]; then
    info "or from your admin account, exactly like the weekly run: sudo launchctl kickstart system/$PLIST_NAME"
  fi
fi
echo
echo "All set."
