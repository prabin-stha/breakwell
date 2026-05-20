#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME="BreakWell"
INSTALL_DIR="/Applications"
BUNDLE_ID="com.prabin.BreakWell"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BOLD}==> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Uninstall ${APP_NAME}.

Usage: $(basename "$0") [options]

Options:
  -y, --yes    Skip the confirmation prompt.
  -h, --help   Show this help and exit.

Note: this removes the ${APP_NAME} application bundle only. Your user
data (settings, daily stats) is preserved at
~/Library/Containers/${BUNDLE_ID} so a future reinstall picks up where
you left off. To wipe that too, drag it to the Trash from Finder.
EOF
}

ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: $arg (try --help)" ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This uninstaller only supports macOS."

DEST="${INSTALL_DIR}/${APP_NAME}.app"
CONTAINER="${HOME}/Library/Containers/${BUNDLE_ID}"

if [[ ! -d "$DEST" ]]; then
  warn "${APP_NAME} doesn't appear to be installed at ${DEST}."
  if [[ -d "$CONTAINER" ]]; then
    echo "  (User data still exists at $CONTAINER — drag to Trash from Finder if you want it gone.)"
  fi
  exit 0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
info "About to remove:"
echo "    • $DEST"
[[ -d "$CONTAINER" ]] && warn "User data at $CONTAINER will be preserved."
echo

# ── Confirmation ──────────────────────────────────────────────────────────────
#
# Two things to get right here, both specific to `curl … | bash`:
#
#   1. The prompt has to *appear*. With `read -p`, bash writes the prompt
#      to stderr — usually fine, but in some setups (especially when bash
#      was started with stdin connected to the curl pipe) the prompt is
#      effectively invisible. Writing the prompt to /dev/tty directly
#      side-steps that completely.
#
#   2. `read` has to come from the user's terminal, not the curl pipe. If
#      we read from the pipe, the script's own source code is past EOF
#      and read returns immediately with empty input. /dev/tty is the
#      controlling terminal of the shell session and is always the right
#      thing to read from when stdin is busy with something else.
#
# We also `set +e` / `set -e` around the read because EOF from /dev/tty
# in a weird environment shouldn't take down the whole script.
if [[ $ASSUME_YES -eq 0 ]]; then
  reply=""
  if [[ -t 0 ]]; then
    # Normal interactive run: the user invoked `bash uninstall.sh` directly.
    printf 'Continue? [y/N] '
    set +e; read -r reply; set -e
  elif [[ -r /dev/tty ]]; then
    # `curl … | bash` path: read + write via the controlling terminal.
    printf 'Continue? [y/N] ' > /dev/tty
    set +e; read -r reply < /dev/tty; set -e
  else
    die "Non-interactive shell with no controlling terminal. Re-run with -y to confirm."
  fi
  [[ "$reply" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 1; }
fi

# ── Quit the running app ──────────────────────────────────────────────────────
# Use AppleScript first so the app gets a chance to clean up (release login
# item registration, close windows, save state). Fall back to pkill if it
# doesn't respond — sandboxed apps occasionally ignore AppleScript when not
# the frontmost process.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  info "Quitting running ${APP_NAME}..."
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true

  # Wait up to 3 seconds for graceful exit.
  for _ in 1 2 3; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 1
  done

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    warn "Graceful quit timed out — sending SIGTERM."
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
fi

# ── Remove the app bundle ─────────────────────────────────────────────────────
#
# On macOS 14+ a plain `rm /Applications/X.app` can fail with EPERM even
# under sudo — sudo elevates to root but TCC ("App Management") applies
# to the *terminal process* you're running from. Sudo doesn't bypass it.
#
# Strategy:
#   1. Try `rm` directly. Cheap and silent when it works.
#   2. Fall back to asking Finder to delete via AppleScript. Finder has
#      the necessary entitlement, sends the bundle to Trash (recoverable),
#      and prompts the user once for permission to control Finder — a
#      normal macOS UX.
#   3. Final fallback to `sudo rm`, in case Finder automation is denied
#      but the user does have App Management.
#   4. Check after each step that the path is actually gone, since `rm -rf`
#      can silently fail on partial sub-paths.
remove_app_bundle() {
  rm -rf "$DEST" 2>/dev/null
  [[ ! -e "$DEST" ]] && return 0

  osascript -e "tell application \"Finder\" to delete POSIX file \"$DEST\"" >/dev/null 2>&1
  [[ ! -e "$DEST" ]] && return 0

  sudo rm -rf "$DEST" 2>/dev/null
  [[ ! -e "$DEST" ]] && return 0

  return 1
}

info "Removing ${DEST}..."
if remove_app_bundle; then
  success "App bundle removed."
else
  cat >&2 <<EOF

${RED}✗ Could not remove ${DEST}${NC}

macOS is blocking direct removal. On Sonoma+ the terminal app needs
"App Management" permission — sudo doesn't bypass this because TCC
tracks the calling process, not the UID.

Fix it one of two ways:

  ${BOLD}1.${NC} Grant your terminal the App Management permission:
       System Settings → Privacy & Security → App Management → toggle on
       your terminal app (Terminal / iTerm / Ghostty / etc.), then re-run
       this uninstaller.

  ${BOLD}2.${NC} Or remove it manually via Finder:
       Open /Applications, drag ${APP_NAME} to the Trash, authenticate
       when prompted.

EOF
  exit 1
fi

# ── Final notes ───────────────────────────────────────────────────────────────
echo
success "${APP_NAME} uninstalled."
echo

# Login item registered via SMAppService is keyed to the .app bundle path.
# Once the bundle is gone, macOS will silently drop the entry on next login
# (or surface "Item missing" in System Settings > General > Login Items).
# Mention it so the user isn't surprised.
echo -e "  ${BOLD}Note:${NC} if you had 'Launch at login' enabled, macOS will"
echo "        clear the orphaned entry on your next login. You can also"
echo "        remove it manually under System Settings > General > Login Items."
