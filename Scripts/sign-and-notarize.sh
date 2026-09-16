#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="${LEFTOPEN_OUTPUT_DIR:-${project_dir}/dist}"
app_path="${output_dir}/LeftOpen.app"
zip_path="${output_dir}/LeftOpen-notarization.zip"
release_zip="${output_dir}/LeftOpen-release.zip"

if [[ -z "${LEFTOPEN_APP_IDENTITY:-}" || -z "${LEFTOPEN_NOTARY_PROFILE:-}" || -z "${LEFTOPEN_BUNDLE_ID:-}" ]]; then
  print -u2 "Set LEFTOPEN_APP_IDENTITY, LEFTOPEN_NOTARY_PROFILE, and LEFTOPEN_BUNDLE_ID explicitly."
  exit 1
fi
if [[ ! -d "$app_path" ]]; then
  print -u2 "Build the app first: $app_path"
  exit 1
fi
if [[ -e "$zip_path" || -e "$release_zip" ]]; then
  print -u2 "Refusing to overwrite an existing zip in $output_dir. Use a new LEFTOPEN_OUTPUT_DIR."
  exit 1
fi
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_path}/Contents/Info.plist")"
if [[ "$actual_bundle_id" != "$LEFTOPEN_BUNDLE_ID" ]]; then
  print -u2 "Bundle ID mismatch: built $actual_bundle_id, requested $LEFTOPEN_BUNDLE_ID."
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$LEFTOPEN_APP_IDENTITY" "$app_path"
codesign --verify --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$LEFTOPEN_NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$release_zip"
print "Notarized release: $release_zip"
