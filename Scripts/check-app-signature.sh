#!/bin/zsh
# The signature gate for a built Obscura.app (redman 2026-10-27: a Release build shipped with get-task-allow).
# Every install to ~/Applications and every release runs this; a non-zero exit stops them.
#   Scripts/check-app-signature.sh <path/to/Obscura.app>            the install gate
#   Scripts/check-app-signature.sh <path/to/Obscura.app> --release  also requires the release-only values (G-33: the
#                                                                    real update public key and feed address). Set
#                                                                    OBSCURA_UPDATE_PUBLIC_KEY to the release key's public half
#                                                                    (`obscura release public-key`): the executable must hold it.
# The executable always holds the placeholder's text (UpdateTrust.placeholder, which the app compares against), so the key
# check is positive: the expected public key must be compiled in, which also refuses a build made with another key.
# Checks (G-33, which supersedes G-11): the signature verifies strictly; the app carries NO entitlements at all — any
# com.apple.security.cs.* key (a hardened-runtime exception such as disable-library-validation) or get-task-allow fails;
# the hardened runtime and library-validation flags are set in the signature; nothing is embedded for dyld to load
# (no Frameworks, no dylibs: a team-less identity's own frameworks would be refused by library validation anyway); every
# rpath stays inside the bundle or the system Swift libraries; no Sparkle leftovers; no placeholder values; a release
# names no earlier identity (G-38).
set -u
app="${1:-}"
mode="${2:-install}"
[[ -d "$app" ]] || { print -u2 "usage: $0 <Obscura.app> [--release]"; exit 2; }
fail=0
ok()  { print "ok    $1"; }
bad() { print "FAIL  $1"; fail=1; }

if codesign --verify --deep --strict "$app" 2>/dev/null; then ok "signature verifies (deep, strict)"; else bad "signature does not verify"; fi

# No entitlements: either no entitlements blob, or an empty dictionary.
actual=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null \
  | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",",":")))' 2>/dev/null)
if [[ -z "$actual" || "$actual" == "{}" ]]; then ok "no entitlements"
else
  bad "entitlements are $actual, expected none"
  print -r -- "$actual" | grep -q '"com\.apple\.security\.cs\.' && bad "a hardened-runtime exception (com.apple.security.cs.*) is present"
  print -r -- "$actual" | grep -q 'get-task-allow' && bad "get-task-allow is present"
fi

flags=$(codesign -dvv "$app" 2>&1 | grep -E '^CodeDirectory' | head -1)
if print -r -- "$flags" | grep -q "runtime"; then ok "hardened runtime flag set"; else bad "hardened runtime flag missing"; fi
if print -r -- "$flags" | grep -q "library-validation"; then ok "library-validation flag set"; else bad "library-validation flag missing"; fi

embedded=$(find "$app/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.bundle' \) -prune -print 2>/dev/null)
if [[ -z "$embedded" ]]; then ok "no embedded frameworks, dylibs, XPC services or bundles"
else bad "embedded code library validation would refuse: ${embedded//$'\n'/, }"; fi

exe="$app/Contents/MacOS/Obscura"
rpaths=$(otool -l "$exe" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; print $2}' | sort -u)
stray=$(print -r -- "$rpaths" | grep -vE '^(@executable_path/\.\./Frameworks|/usr/lib/swift)$' | grep -v '^$')
if [[ -z "$stray" ]]; then ok "rpaths stay in the bundle or /usr/lib/swift"; else bad "rpaths outside the bundle: ${stray//$'\n'/, }"; fi

plist="$app/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c "Print" "$plist" 2>/dev/null | grep -qE '^ *SU[A-Za-z]+ = '; then bad "Info.plist still holds Sparkle (SU*) keys"
else ok "no Sparkle keys in Info.plist"; fi

feed=$(/usr/libexec/PlistBuddy -c "Print :ObscuraUpdateFeedURL" "$plist" 2>/dev/null)
if [[ "$mode" == "--release" ]]; then
  expected="${OBSCURA_UPDATE_PUBLIC_KEY:-}"
  if [[ ! "$expected" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then bad "set OBSCURA_UPDATE_PUBLIC_KEY to the release key's public half (obscura release public-key)"
  elif LC_ALL=C grep -a -q -F "$expected" "$exe"; then ok "the executable holds the release update public key"
  else bad "the executable does not hold the release update public key (built with the placeholder or another key)"; fi
  if grep -q "REPLACE_WITH" "$plist"; then bad "Info.plist still holds a REPLACE_WITH placeholder (set OBSCURA_UPDATE_FEED_URL)"; else ok "no placeholders in Info.plist"; fi
  if [[ "$feed" == https://* ]]; then ok "ObscuraUpdateFeedURL is https"; else bad "ObscuraUpdateFeedURL is not https: ${feed:-missing}"; fi
  # G-38: a public build never names an earlier identity (OBSCURA_PREVIOUS_IDENTITY, Apps/Obscura/Identity.xcconfig).
  previous=$(/usr/libexec/PlistBuddy -c "Print :ObscuraPreviousIdentity" "$plist" 2>/dev/null)
  if [[ -z "$previous" ]]; then ok "no earlier identity named"
  else bad "Info.plist names an earlier identity (empty OBSCURA_PREVIOUS_IDENTITY for a release)"; fi
  # G-38: a public build names no build Mac's home folder, in any file or in the executable's symbol table (the debug
  # map an unstripped build keeps; project.yml's Release config strips it).
  homes=$(LC_ALL=C grep -rla -E '/Users/[^/[:space:]]+/' "$app" 2>/dev/null)
  stabs=$(nm -ap "$exe" 2>/dev/null | grep -cE ' (SO|OSO|SOL) +/')
  if [[ -z "$homes" && "$stabs" == 0 ]]; then ok "no home folder path and no debug map in the bundle"
  else bad "the bundle names a build Mac's folder (files: ${homes//$'\n'/, }; debug-map entries: $stabs) — strip the Release build"; fi
  if codesign -dvv "$app" 2>&1 | grep -q '^Signature=adhoc'; then bad "ad-hoc signature: an ad-hoc release can never verify its own updates (sign with the release identity)"
  else ok "signed with a certificate identity"; fi
else
  grep -q "REPLACE_WITH" "$plist" && print "note  Info.plist holds a placeholder (allowed for a local install, refused with --release)"
fi

(( fail )) && { print "signature gate: FAILED"; exit 1; }
print "signature gate: passed"
