#!/bin/sh
# Render actual AppKit panels at 2x in both languages and color schemes for the README and site.
# Launch arguments override language for each capture without changing the user's saved preference.
set -eu
cd "$(dirname "$0")/.."
snapshot_app="${LEFTOPEN_SNAPSHOT_APP:-.build/debug/LeftOpenApp}"
if [ -z "${LEFTOPEN_SNAPSHOT_APP:-}" ]; then swift build >/dev/null; fi
for language in en zh; do
  suffix=""
  if [ "$language" = zh ]; then suffix="-zh"; fi
  LEFTOPEN_SNAPSHOT="$PWD/assets/preview${suffix}.png" "$snapshot_app" -leftopen.language "$language"
  LEFTOPEN_SNAPSHOT="$PWD/assets/preview${suffix}-dark.png" LEFTOPEN_SNAPSHOT_DARK=1 "$snapshot_app" -leftopen.language "$language"
  cp "assets/preview${suffix}.png" "assets/preview${suffix}-dark.png" docs/assets/
done
