#!/bin/zsh
# Verifies that the app installed on a simulator is byte-for-byte the build in DerivedData,
# and optionally that its binaries contain (or do not contain) a marker string.
#
# A build log saying BUILD SUCCEEDED does not mean the change reached the binary: a changed
# default-argument value in the DiscogsKit package rebuilds the package but not the modules that
# call it, because the default is materialised at the call site. Check the installed binary.
#
# Usage:
#   Scripts/verify-installed.sh <udid> [--expect <string>] [--forbid <string>]
set -eu

UDID="${1:?usage: verify-installed.sh <udid> [--expect s] [--forbid s]}"
shift
BUNDLE_ID="com.mlkshkvch.catalogista"
# The Debug simulator build of this checkout, wherever DerivedData put it. DERIVED_APP overrides.
REPO="${0:A:h:h}"
if [[ -z "${DERIVED_APP:-}" ]]; then
  PRODUCTS=$(xcodebuild -project "$REPO/Catalogista.xcodeproj" -scheme Catalogista -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
  [[ -n "$PRODUCTS" ]] || { print -u2 "FAIL: no Catalogista.xcodeproj build settings — run make generate"; exit 1; }
fi
BUILT="${DERIVED_APP:-$PRODUCTS/Catalogista.app}"

EXPECT=""
FORBID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect) EXPECT="$2"; shift 2 ;;
    --forbid) FORBID="$2"; shift 2 ;;
    *) print -u2 "unknown argument: $1"; exit 2 ;;
  esac
done

INSTALLED="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)"

fail() { print -u2 "FAIL: $1"; exit 1; }

for binary in "Catalogista" "Frameworks/CatalogistaKit.framework/CatalogistaKit"; do
  [[ -f "$BUILT/$binary" ]] || fail "no built binary at $BUILT/$binary — build first"
  [[ -f "$INSTALLED/$binary" ]] || fail "no installed binary at $INSTALLED/$binary"
  if ! cmp -s "$BUILT/$binary" "$INSTALLED/$binary"; then
    fail "$binary on the simulator differs from the build — reinstall before testing"
  fi
done

if [[ -n "$EXPECT" ]]; then
  strings "$INSTALLED/Frameworks/CatalogistaKit.framework/CatalogistaKit" "$INSTALLED/Catalogista" \
    | grep -qF -- "$EXPECT" || fail "installed binary does not contain \"$EXPECT\""
fi

if [[ -n "$FORBID" ]]; then
  if strings "$INSTALLED/Frameworks/CatalogistaKit.framework/CatalogistaKit" "$INSTALLED/Catalogista" \
    | grep -qF -- "$FORBID"; then
    fail "installed binary still contains \"$FORBID\""
  fi
fi

print "OK: the simulator is running this build."
