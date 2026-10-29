#!/bin/bash
# Writes the signed update feed (G-33) for one release disk image. Replaces Sparkle's generate_appcast.
#   Scripts/make-feed.sh <Obscura.app> <Obscura-<version>_<build>.dmg> <https download url> [<https release notes url>]
# The update key is read from the login-Keychain item named by OBSCURA_UPDATE_KEY_ITEM (created once with
# `obscura release keygen`, the maintainer's release step); the private key is never printed or written. Output:
# dist/obscura-update.json, published at the app's ObscuraUpdateFeedURL together with the DMG at <download url>.
# The DMG must be served at <download url> WITHOUT a redirect to another host (Obscura refuses cross-host redirects),
# so it goes next to the feed on GitHub Pages, not on a GitHub Releases asset link (those redirect to another host).
set -euo pipefail
APP="${1:?path to the Obscura.app inside the DMG}"; DMG="${2:?path to the DMG}"; URL="${3:?https download URL of the DMG}"
NOTES="${4:-}"
: "${OBSCURA_UPDATE_KEY_ITEM:?set OBSCURA_UPDATE_KEY_ITEM to the Keychain item holding the update key}"
OUT="${FEED_OUT:-dist/obscura-update.json}"
mkdir -p "$(dirname "$OUT")"
swift build -c release --product obscura >/dev/null
OBSCURA="$(swift build -c release --show-bin-path)/obscura"
# The app must pass the release gate first: the Keychain key's public half compiled in, the real feed address, a
# certificate signature, no entitlements.
OBSCURA_UPDATE_PUBLIC_KEY="$("$OBSCURA" release public-key --key-item "$OBSCURA_UPDATE_KEY_ITEM")" \
  "$(dirname "$0")/check-app-signature.sh" "$APP" --release
args=(release feed --app "$APP" --dmg "$DMG" --url "$URL" --key-item "$OBSCURA_UPDATE_KEY_ITEM" --out "$OUT")
[ -n "$NOTES" ] && args+=(--notes-url "$NOTES")
"$OBSCURA" "${args[@]}"
