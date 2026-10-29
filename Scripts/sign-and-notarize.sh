#!/bin/bash
# Signs (and optionally notarizes) Obscura.app. Ad-hoc by default (G-4: no developer account yet).
# Set SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" and NOTARIZE=1 (with NOTARY_PROFILE from
# `xcrun notarytool store-credentials`) to switch to a real signature — a config change, not a code change.
# G-33: hardened runtime AND library validation, no entitlements (Apps/Obscura/Obscura.entitlements is an empty
# dictionary); the signature gate runs after signing and refuses anything else.
set -euo pipefail
APP="${1:?path to Obscura.app}"
# Default: the local "Obscura Self-Signed" identity when this Mac has it (a stable code identity, so users keep
# folder access across updates and updates verify against it), else ad-hoc (a local build only: an ad-hoc copy can
# never verify an update, and check-app-signature.sh --release refuses it).
DEFAULT_IDENTITY="-"
security find-identity -p codesigning 2>/dev/null | grep -q '"Obscura Self-Signed"' && DEFAULT_IDENTITY="Obscura Self-Signed"
IDENTITY="${SIGNING_IDENTITY:-$DEFAULT_IDENTITY}"
codesign --force --timestamp --options runtime,library \
  --entitlements "$(dirname "$0")/../Apps/Obscura/Obscura.entitlements" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
"$(dirname "$0")/check-app-signature.sh" "$APP"
if [ "${NOTARIZE:-0}" = "1" ]; then
  [ "$IDENTITY" != "-" ] || { echo "NOTARIZE=1 needs a Developer ID SIGNING_IDENTITY"; exit 1; }
  ZIP="$(mktemp -d)/Obscura.zip"; ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "${NOTARY_PROFILE:?}" --wait
  xcrun stapler staple "$APP"
fi
echo "signed: $APP (identity: $IDENTITY, notarized: ${NOTARIZE:-0})"
