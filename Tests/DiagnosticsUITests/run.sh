#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
test_dir="$(mktemp -d /private/tmp/leftopen-diagnostics-ui.XXXXXX)"
app="$test_dir/LeftOpenDiagnosticsTest.app"
mkdir -p "$app/Contents/MacOS"
swiftc -emit-library -emit-module -module-name LeftOpenCore Sources/LeftOpenCore/FailureDiagnostics.swift \
  -o "$test_dir/libLeftOpenCore.dylib" -emit-module-path "$test_dir/LeftOpenCore.swiftmodule"
swiftc -I "$test_dir" -L "$test_dir" -lLeftOpenCore -Xlinker -rpath -Xlinker "$test_dir" \
  Sources/LeftOpenApp/ErrorDiagnosticsView.swift Tests/DiagnosticsUITests/main.swift \
  -o "$app/Contents/MacOS/LeftOpenDiagnosticsTest"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string LeftOpenDiagnosticsTest "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string app.leftopen.diagnostics-test "$app/Contents/Info.plist"
plutil -insert CFBundleName -string LeftOpenDiagnosticsTest "$app/Contents/Info.plist"
print "UI fixture: $app"
"$app/Contents/MacOS/LeftOpenDiagnosticsTest"
