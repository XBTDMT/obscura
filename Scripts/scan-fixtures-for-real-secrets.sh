#!/bin/bash
# Fails if any fixture or source file contains a string shaped like a LIVE credential that is not on the
# allow-list of generator outputs. Every secret in this repo must be made up; this is the gate that proves it.
set -euo pipefail
cd "$(dirname "$0")/.."
ALLOW='Tests/Fixtures/allowlist.txt'
touch "$ALLOW"
# Shapes that are almost never false positives for real keys: AWS key ids, GitHub tokens with a valid-looking body, Stripe live keys, Slack bot tokens, private key blocks with real-looking base64 bodies.
PATTERN='AKIA[A-Z0-9]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{80,}|sk_live_[A-Za-z0-9]{24,}|xoxb-[0-9]{10,}-[0-9]{10,}-[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
hits=$(grep -rnoE "$PATTERN" Sources Tests Tools Apps 2>/dev/null | grep -vFf "$ALLOW" || true)
if [ -n "$hits" ]; then
  echo "Possible real credential shapes found (add to $ALLOW only if you generated them):"; echo "$hits"; exit 1
fi
echo "fixtures clean"
