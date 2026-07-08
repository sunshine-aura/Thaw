#!/usr/bin/env bash
#
# thaw-devrun.sh — Build the Debug config and run it from /Applications so the
# macOS 27 menu-bar hiding feature works with a local build.
#
# Why this exists: on macOS 27 a status item's menu-bar scene is only attributed
# to its app when the app has a clean code identity AND a canonical /Applications
# location. A Debug build run straight from DerivedData/Xcode hosts its status
# item as `nil`, so the visibility-restriction allowlist can't protect it and
# Thaw's own icon vanishes whenever anything is hidden.
#
# This script builds with your Apple Development signing identity (see
# scripts/signing.local.sh.example), quits any running 'Thaw Debug' (the app AND
# its XPC service), deletes the old `/Applications/Thaw Debug.app`, installs the
# fresh build, and launches it.
#
# Usage:
#   ./scripts/thaw-devrun.sh
#   ./scripts/thaw-devrun.sh --team A7CKWF99ML
#   THAW_DEVELOPMENT_TEAM=A7CKWF99ML ./scripts/thaw-devrun.sh
#
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=lib/signing.sh
source "${REPO_ROOT}/scripts/lib/signing.sh"

SCHEME="Thaw"
CONFIG="Debug"
DEST="/Applications/Thaw Debug.app"
DEBUG_BUNDLE_ID="com.stonerl.Thaw.debug"

TEAM_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team)
            TEAM_OVERRIDE="${2:?--team requires a team id}"
            shift 2
            ;;
        -h | --help)
            sed -n '1,22p' "$0" | tail -n +2
            echo ""
            signing_setup_hint
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 2
            ;;
    esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [[ -n "$TEAM_OVERRIDE" ]]; then
    export THAW_DEVELOPMENT_TEAM="$TEAM_OVERRIDE"
fi

DEVELOPMENT_TEAM=""
if DEVELOPMENT_TEAM="$(resolve_development_team "$REPO_ROOT")"; then
    say "Signing with Apple Development team ${DEVELOPMENT_TEAM}"
else
    echo "error: no development team configured." >&2
    echo >&2
    signing_setup_hint >&2
    exit 1
fi

# Quit every running 'Thaw Debug' process — the app AND its MenuBarItemService
# XPC child — without touching a release `Thaw`. Matches on the install path so
# it's precise. Tries a graceful quit first (clean assertion teardown), then
# force-kills anything still alive. The hiding assertion auto-releases on exit,
# so a force-kill leaves no lingering restriction.
quit_thaw_debug() {
    pgrep -f "$DEST/" >/dev/null 2>&1 || return 0

    say "Quitting running 'Thaw Debug'…"
    # Backgrounded so a macOS 27 quit-hang can't stall the script.
    ( osascript -e "tell application id \"$DEBUG_BUNDLE_ID\" to quit" >/dev/null 2>&1 ) &

    # Poll up to ~4s for the app + XPC service to exit on their own.
    for _ in {1..8}; do
        pgrep -f "$DEST/" >/dev/null 2>&1 || return 0
        sleep 0.5
    done

    say "Force-killing leftover 'Thaw Debug' processes…"
    pkill -9 -f "$DEST/" 2>/dev/null || true
    sleep 1
}

say "Building ${CONFIG}…"
xcodebuild -project Thaw.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    "CODE_SIGN_IDENTITY=Apple Development" \
    build >/dev/null

PRODUCTS_DIR=$(xcodebuild -project Thaw.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Automatic \
    "CODE_SIGN_IDENTITY=Apple Development" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="${PRODUCTS_DIR}/Thaw.app"
[ -d "$APP" ] || { echo "Build product not found: $APP"; exit 1; }

quit_thaw_debug

if [ -e "$DEST" ]; then
    say "Removing existing ${DEST}…"
    rm -rf "$DEST"
fi

say "Installing to ${DEST}…"
mv "$APP" "$DEST"

say "Launching…"
open "$DEST"
say "Running 'Thaw Debug'. First launch: grant Accessibility + Screen Recording."
