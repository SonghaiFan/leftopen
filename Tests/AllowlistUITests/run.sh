#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
test_dir="$(mktemp -d /private/tmp/leftopen-allowlist-ui.XXXXXX)"
app="$test_dir/LeftOpenAllowlistTest.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 6 -emit-library -emit-module -module-name LeftOpenCore Sources/LeftOpenCore/Localization.swift \
  -o "$test_dir/libLeftOpenCore.dylib" -emit-module-path "$test_dir/LeftOpenCore.swiftmodule"
swiftc -swift-version 6 -I "$test_dir" -L "$test_dir" -lLeftOpenCore -Xlinker -rpath -Xlinker "$test_dir" \
  Sources/LeftOpenApp/AppSettings.swift Sources/LeftOpenApp/AppAppearance.swift \
  Sources/LeftOpenApp/PortAllowlistInput.swift Tests/AllowlistUITests/main.swift \
  -o "$app/Contents/MacOS/LeftOpenAllowlistTest"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string LeftOpenAllowlistTest "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string app.leftopen.allowlist-test "$app/Contents/Info.plist"
plutil -insert CFBundleName -string LeftOpenAllowlistTest "$app/Contents/Info.plist"
print "UI fixture: $app"
"$app/Contents/MacOS/LeftOpenAllowlistTest"
