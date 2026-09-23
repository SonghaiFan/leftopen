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
# Build both slices even when packaging on an Apple Silicon or Intel host.
build_args=(-c release -debug-info-format none --disable-sandbox --arch arm64 --arch x86_64)
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
for executable in LeftOpenApp leftopen; do
  if [[ ! -x "${binary_dir}/${executable}" ]]; then
    print -u2 "Missing release executable: ${binary_dir}/${executable}"
    exit 1
  fi
done

mkdir -p "${app_path}/Contents/MacOS"
for executable in LeftOpenApp leftopen; do
  cp "${binary_dir}/${executable}" "${app_path}/Contents/MacOS/${executable}"
  chmod 755 "${app_path}/Contents/MacOS/${executable}"
done
"${project_dir}/Scripts/verify-universal-app.sh" "$app_path"
cp "${project_dir}/Resources/Info.plist" "${app_path}/Contents/Info.plist"
if [[ -f "${project_dir}/Resources/AppIcon.icns" ]]; then
  mkdir -p "${app_path}/Contents/Resources"
  cp "${project_dir}/Resources/AppIcon.icns" "${app_path}/Contents/Resources/AppIcon.icns"
fi
plutil -replace CFBundleIdentifier -string "$bundle_id" "${app_path}/Contents/Info.plist"
# Sign nested code before the bundle, which signs the main executable too.
codesign --force --sign - "${app_path}/Contents/MacOS/leftopen"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict --all-architectures "$app_path"
print "Built ad-hoc signed app: $app_path"
