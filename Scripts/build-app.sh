#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${LEFTOPEN_OUTPUT_DIR:-${project_dir}/dist}"
app_path="${output_dir}/LeftOpen.app"
bundle_id="${LEFTOPEN_BUNDLE_ID:-app.leftopen.mac}"

if [[ -e "$app_path" ]]; then
  print -u2 "Refusing to overwrite existing app: $app_path"
  print -u2 "Set LEFTOPEN_OUTPUT_DIR to a new directory for another build."
  exit 1
fi

cd "$project_dir"
swift build -c release -debug-info-format none --disable-sandbox
binary_dir="$(swift build -c release -debug-info-format none --disable-sandbox --show-bin-path)"
binary_path="${binary_dir}/LeftOpenApp"
if [[ ! -x "$binary_path" ]]; then
  print -u2 "Missing release executable: $binary_path"
  exit 1
fi

mkdir -p "${app_path}/Contents/MacOS"
cp "$binary_path" "${app_path}/Contents/MacOS/LeftOpenApp"
cp "${project_dir}/Resources/Info.plist" "${app_path}/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "${app_path}/Contents/Info.plist"
chmod 755 "${app_path}/Contents/MacOS/LeftOpenApp"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
print "Built ad-hoc signed app: $app_path"
