#!/bin/sh
# Renders the menu bar panel at 2x (light + dark) into assets/ and docs/assets/ for README and
# the site. Uses the LEFTOPEN_SNAPSHOT hook in the app; run from the repo root after `swift build`.
set -eu
cd "$(dirname "$0")/.."
swift build >/dev/null
LEFTOPEN_SNAPSHOT="$PWD/assets/preview.png" .build/debug/LeftOpenApp
LEFTOPEN_SNAPSHOT="$PWD/assets/preview-dark.png" LEFTOPEN_SNAPSHOT_DARK=1 .build/debug/LeftOpenApp
cp assets/preview.png assets/preview-dark.png docs/assets/
