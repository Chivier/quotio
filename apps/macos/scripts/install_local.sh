#!/bin/bash
# Build the Debug app, re-sign it with a stable local identity, and install it.
#
# Ad-hoc signatures change on every build, and macOS ties Keychain access to the
# signature, so each new build has to be authorized again. A self-signed identity
# that stays the same across builds keeps those authorizations valid.
#
# Usage: LOCAL_SIGNING_IDENTITY="Quotio Local Signing" ./apps/macos/scripts/install_local.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${LOCAL_SIGNING_IDENTITY:-Quotio Local Signing}"
DERIVED_DATA="${PROJECT_DIR}/build/DebugDerivedData"
BUILT_APP="${DERIVED_DATA}/Build/Products/Debug/Quotio.app"
TARGET_APP="/Applications/Quotio.app"
# Kept outside /Applications so Spotlight and Launchpad show only one Quotio.
PREVIOUS_APP="${PROJECT_DIR}/build/Quotio.previous.app"
ENTITLEMENTS="${PROJECT_DIR}/Quotio/Quotio.entitlements"

if ! security find-certificate -c "${IDENTITY}" >/dev/null 2>&1; then
    echo "error: signing identity '${IDENTITY}' not found in the keychain" >&2
    exit 1
fi

echo "==> Building Quotio (Debug)"
xcodebuild \
    -project "${PROJECT_DIR}/Quotio.xcodeproj" \
    -scheme Quotio \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    build >"${PROJECT_DIR}/build/install-build.log" 2>&1 \
    || { echo "error: build failed; see build/install-build.log" >&2; exit 1; }

echo "==> Signing with '${IDENTITY}'"
codesign --force --deep --sign "${IDENTITY}" --entitlements "${ENTITLEMENTS}" "${BUILT_APP}"
codesign --verify --deep --strict "${BUILT_APP}"

echo "==> Installing to ${TARGET_APP}"
pkill -x Quotio 2>/dev/null || true
sleep 1
if [ -d "${TARGET_APP}" ]; then
    rm -rf "${PREVIOUS_APP}"
    mv "${TARGET_APP}" "${PREVIOUS_APP}"
fi
ditto "${BUILT_APP}" "${TARGET_APP}"
open "${TARGET_APP}"
echo "==> Installed; the previous app is at ${PREVIOUS_APP}"
