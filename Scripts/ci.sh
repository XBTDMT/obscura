#!/bin/bash
# Full local CI: engine build + tests, app project generation + build, fixture secret-shape scan.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== swift build (release)"; swift build -c release 2>&1 | tail -3
echo "== swift test"; swift test 2>&1 | grep -E 'Test run with|✘' | tail -20
echo "== fixture secret-shape scan"; Scripts/scan-fixtures-for-real-secrets.sh
if command -v xcodegen >/dev/null; then
  echo "== xcodegen + xcodebuild"; xcodegen generate -q
  xcodebuild -project Obscura.xcodeproj -scheme Obscura -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'error|BUILD' | tail -5
fi
echo "CI OK"
