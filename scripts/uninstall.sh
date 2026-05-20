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
  --purge      Also remove user data — settings, daily stats, caches, and
               saved application state. Without this flag, your preferences
               are preserved so a future reinstall picks up where you
               left off.
  -y, --yes    Skip the confirmation prompt.
  -h, --help   Show this help and exit.
EOF
}

PURGE=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge)   PURGE=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: $arg (try --help)" ;;
  esac
done

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This uninstaller only supports macOS."

DEST="${INSTALL_DIR}/${APP_NAME}.app"
CONTAINER="${HOME}/Library/Containers/${BUNDLE_ID}"
APP_SCRIPTS="${HOME}/Library/Application Scripts/${BUNDLE_ID}"

APP_EXISTS=0
DATA_EXISTS=0
[[ -d "$DEST" ]]      && APP_EXISTS=1
[[ -d "$CONTAINER" ]] && DATA_EXISTS=1

if [[ $APP_EXISTS -eq 0 && $DATA_EXISTS -eq 0 ]]; then
  warn "${APP_NAME} doesn't appear to be installed — nothing to remove."
  exit 0
fi

# ── Summary + confirmation ────────────────────────────────────────────────────
info "About to remove:"
[[ $APP_EXISTS -eq 1 ]]                    && echo "    • $DEST"
[[ $PURGE -eq 1 && $DATA_EXISTS -eq 1 ]]   && echo "    • $CONTAINER (user data)"
[[ $PURGE -eq 1 && -d "$APP_SCRIPTS" ]]    && echo "    • $APP_SCRIPTS"
[[ $PURGE -eq 0 && $DATA_EXISTS -eq 1 ]]   && warn "User data at $CONTAINER will be PRESERVED. Pass --purge to remove it too."
echo

if [[ $ASSUME_YES -eq 0 ]]; then
  read -rp "Continue? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 1; }
fi

# ── Quit the running app ──────────────────────────────────────────────────────
# Use AppleScript first so the app gets a chance to clean up (release login
# item registration, close windows, save state). Fall back to pkill if it
# didn't respond — sandboxed apps occasionally ignore AppleScript when not
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
if [[ $APP_EXISTS -eq 1 ]]; then
  info "Removing ${DEST}..."
  if [[ -w "$INSTALL_DIR" && -w "$DEST" ]]; then
    rm -rf "$DEST"
  else
    sudo rm -rf "$DEST"
  fi
  success "App bundle removed."
fi

# ── Optionally remove user data ───────────────────────────────────────────────
if [[ $PURGE -eq 1 ]]; then
  if [[ $DATA_EXISTS -eq 1 ]]; then
    info "Removing user data at ${CONTAINER}..."
    rm -rf "$CONTAINER"
    success "User data removed."
  fi
  if [[ -d "$APP_SCRIPTS" ]]; then
    info "Removing ${APP_SCRIPTS}..."
    rm -rf "$APP_SCRIPTS"
  fi
fi

# ── Final notes ───────────────────────────────────────────────────────────────
echo
success "${APP_NAME} uninstalled."
echo

# Login item registered via SMAppService is keyed to the .app bundle path.
# Once the bundle is gone, macOS will silently drop the entry on next login
# (or surface "Item missing" in System Settings > General > Login Items).
# Mention it so the user isn't surprised.
if [[ $APP_EXISTS -eq 1 ]]; then
  echo -e "  ${BOLD}Note:${NC} if you had 'Launch at login' enabled, macOS will"
  echo "        clear the orphaned entry on your next login. You can also"
  echo "        remove it manually under System Settings > General > Login Items."
fi
