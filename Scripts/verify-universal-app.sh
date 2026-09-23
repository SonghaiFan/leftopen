#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: $0 /path/to/LeftOpen.app"
  exit 1
fi

for executable in LeftOpenApp leftopen; do
  binary_path="$1/Contents/MacOS/${executable}"
  if [[ ! -x "$binary_path" ]]; then
    print -u2 "Missing app executable: $binary_path"
    exit 1
  fi
  architectures="$(xcrun lipo -archs "$binary_path")"
  if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    print -u2 "Expected both Apple Silicon (arm64) and Intel (x86_64) in $binary_path"
    exit 1
  fi
  print "Verified ${executable}: $architectures"
done
