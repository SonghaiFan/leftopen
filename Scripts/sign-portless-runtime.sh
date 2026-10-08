#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  print -u2 "Usage: $0 /path/to/Portless [signing-identity]"
  exit 1
fi
project_dir="${0:A:h:h}"
identity="${2:--}"
timestamp_args=()
if [[ "$identity" != - ]]; then
  timestamp_args=(--timestamp)
fi
for architecture in arm64 x64; do
  entitlements="${project_dir}/Resources/Portless/node-entitlements.plist"
  if [[ "$architecture" == x64 ]]; then
    entitlements="${project_dir}/Resources/Portless/node-x64-entitlements.plist"
  fi
  # Keep local/CI and Developer ID signing on the same hardened-runtime policy.
  codesign --force --options runtime "${timestamp_args[@]}" --sign "$identity" \
    --entitlements "$entitlements" "$1/node-${architecture}"
done
