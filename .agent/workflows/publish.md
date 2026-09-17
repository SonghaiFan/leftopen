---
name: publish
description: Complete end-to-end publishing workflow for LeftOpen including building, signing, Apple notarization, GitHub release, and Homebrew tap update.
---

# LeftOpen Release & Publish Workflow

See root [`agent.md`](../../agent.md) for full documentation.

## Quick Runbook

```bash
# 1. Set environment variables
export NEW_VERSION="0.2.3"
export NEW_BUILD="5"
export LEFTOPEN_APP_IDENTITY="Developer ID Application: songhai fan (3XYUL6YP53)"
export LEFTOPEN_NOTARY_PROFILE="leftopen-notary"
export LEFTOPEN_BUNDLE_ID="app.leftopen.mac"
export LEFTOPEN_OUTPUT_DIR="dist/v${NEW_VERSION}"

# 2. Pre-flight tests
swift test

# 3. Bump version in Info.plist, main.swift, package.json, src/cli.ts, docs/index.html

# 4. Compile and package app bundle
LEFTOPEN_OUTPUT_DIR="$LEFTOPEN_OUTPUT_DIR" Scripts/build-app.sh

# 5. Sign, notarize with Apple, and staple
LEFTOPEN_OUTPUT_DIR="$LEFTOPEN_OUTPUT_DIR" \
LEFTOPEN_APP_IDENTITY="$LEFTOPEN_APP_IDENTITY" \
LEFTOPEN_NOTARY_PROFILE="$LEFTOPEN_NOTARY_PROFILE" \
LEFTOPEN_BUNDLE_ID="$LEFTOPEN_BUNDLE_ID" \
Scripts/sign-and-notarize.sh

# 6. Checksum and artifact
cp "${LEFTOPEN_OUTPUT_DIR}/LeftOpen-release.zip" LeftOpen.zip
shasum -a 256 LeftOpen.zip

# 7. Git commit, tag, push
git add -A
git commit -m "Release v${NEW_VERSION}"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
git push origin main
git push origin "v${NEW_VERSION}"

# 8. GitHub release
gh release create "v${NEW_VERSION}" LeftOpen.zip \
  --title "v${NEW_VERSION} - Native leftopen CLI & App Bundle" \
  --notes "LeftOpen ${NEW_VERSION}"

# 9. Update Homebrew tap
# Update Casks/leftopen.rb version and sha256, then commit and push.

# 10. Post-release verification
brew update && brew info --cask songhaifan/tap/leftopen
brew fetch --cask songhaifan/tap/leftopen
curl -sI https://songhaifan.github.io/leftopen/
```
