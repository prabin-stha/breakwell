#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITHUB_ORG="prabin-stha"
GITHUB_REPO="breakwell"
APP_NAME="BreakWell"          # Name of the .app bundle inside the zip
INSTALL_DIR="/Applications"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BOLD}==> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This installer only supports macOS."
command -v curl &>/dev/null  || die "curl is required but not found."
command -v unzip &>/dev/null || die "unzip is required but not found."

# ── Detect architecture ───────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  ASSET_ARCH="arm64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  *)      die "Unsupported architecture: $ARCH" ;;
esac

# ── Fetch latest release info ─────────────────────────────────────────────────
info "Fetching latest release info..."
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/releases/latest")
TAG=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
[[ -n "$TAG" ]] || die "Could not determine latest release tag. Check that releases exist on GitHub."

# Try arch-specific asset first, then fall back to a universal build
ASSET_URL=$(echo "$RELEASE_JSON" | grep "browser_download_url" | grep -i "${ASSET_ARCH}.*\.zip\|\.zip.*${ASSET_ARCH}" | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
if [[ -z "$ASSET_URL" ]]; then
  ASSET_URL=$(echo "$RELEASE_JSON" | grep "browser_download_url" | grep -i "\.zip" | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
fi
[[ -n "$ASSET_URL" ]] || die "No .zip asset found in release $TAG. Attach a .zip containing ${APP_NAME}.app to the GitHub release."

info "Installing ${APP_NAME} ${TAG} (${ARCH})..."

# ── Download ──────────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_PATH="${TMP_DIR}/${APP_NAME}.zip"
info "Downloading from GitHub..."
curl -fsSL --progress-bar "$ASSET_URL" -o "$ZIP_PATH"

# ── Extract ───────────────────────────────────────────────────────────────────
info "Extracting..."
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

APP_BUNDLE=$(find "$TMP_DIR" -maxdepth 2 -name "*.app" | head -1)
[[ -n "$APP_BUNDLE" ]] || die "No .app bundle found inside the zip."

# ── Install to /Applications ──────────────────────────────────────────────────
DEST="${INSTALL_DIR}/${APP_NAME}.app"

if [[ -d "$DEST" ]]; then
  warn "Existing installation found at $DEST — replacing it."
  if [[ -w "$INSTALL_DIR" ]]; then
    rm -rf "$DEST"
  else
    sudo rm -rf "$DEST"
  fi
fi

info "Installing to ${DEST}..."
# Use sudo only if /Applications isn't writable by current user
if [[ -w "$INSTALL_DIR" ]]; then
  cp -R "$APP_BUNDLE" "$DEST"
else
  sudo cp -R "$APP_BUNDLE" "$DEST"
fi

# ── Fix permissions ───────────────────────────────────────────────────────────
info "Setting permissions..."
if [[ -w "$DEST" ]]; then
  chmod -R 755 "$DEST"
else
  sudo chmod -R 755 "$DEST"
fi

# ── Remove quarantine (Gatekeeper bypass for unsigned apps) ───────────────────
info "Removing Gatekeeper quarantine..."
if [[ -w "$DEST" ]]; then
  xattr -cr "$DEST" 2>/dev/null || true
else
  sudo xattr -cr "$DEST" 2>/dev/null || true
fi

success "${APP_NAME} ${TAG} installed successfully!"
echo
echo -e "  ${BOLD}Open it:${NC}  open -a \"${APP_NAME}\""
echo -e "  ${BOLD}Or find it in Finder:${NC} /Applications/${APP_NAME}.app"
