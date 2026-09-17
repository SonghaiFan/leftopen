# LeftOpen Release & Publish Workflow

This document defines the end-to-end publishing workflow for LeftOpen. It is designed for autonomous execution by AI agents and maintainers to build, sign, notarize, release, and distribute new versions of LeftOpen.

---

## 1. Prerequisites and Environment

Ensure the following tools, credentials, and permissions are available before initiating a release:

- **Operating System**: macOS Sonoma 14.0 or later on Apple Silicon (`arm64`).
- **Build Tools**:
  - Xcode Command Line Tools (`swift`, `codesign`, `xcrun`, `ditto`, `plutil`).
  - GitHub CLI (`gh`), authenticated with repository write access to `SonghaiFan/leftopen`.
  - Homebrew (`brew`) installed.
- **Signing and Notarization Credentials**:
  - Developer ID Application identity: `Developer ID Application: songhai fan (3XYUL6YP53)`
  - Keychain notary profile: `leftopen-notary`
  - Bundle Identifier: `app.leftopen.mac`
- **Git Repositories**:
  - Main repository: `https://github.com/SonghaiFan/leftopen.git` (working directory on `main`).
  - Homebrew tap repository: `https://github.com/SonghaiFan/homebrew-tap.git`.

---

## 2. Configuration Variables

Define the target version and paths for the release:

```bash
export NEW_VERSION="0.2.3"          # Semantic version (X.Y.Z)
export NEW_BUILD="5"                # Monotonically increasing build integer
export LEFTOPEN_APP_IDENTITY="Developer ID Application: songhai fan (3XYUL6YP53)"
export LEFTOPEN_NOTARY_PROFILE="leftopen-notary"
export LEFTOPEN_BUNDLE_ID="app.leftopen.mac"
export LEFTOPEN_OUTPUT_DIR="dist/v${NEW_VERSION}"
```

---

## 3. Workflow Steps

### Step 1: Pre-flight Verification

Confirm git state is clean and existing tests pass:

```bash
cd "$(git rev-parse --show-toplevel)"

# Verify git working tree is clean
git status

# Run unit tests
swift test
```

---

### Step 2: Version Bumping

Update version strings across project files:

1. **`Resources/Info.plist`**:
   - Set `CFBundleShortVersionString` to `${NEW_VERSION}`.
   - Set `CFBundleVersion` to `${NEW_BUILD}`.

   ```bash
   plutil -replace CFBundleShortVersionString -string "$NEW_VERSION" Resources/Info.plist
   plutil -replace CFBundleVersion -string "$NEW_BUILD" Resources/Info.plist
   ```

2. **`Sources/LeftOpenCLI/main.swift`**:
   - Update version check output:
     ```swift
     if args.contains("-v") || args.contains("--version") {
         print("LeftOpen \(NEW_VERSION)")
         exit(0)
     }
     ```

3. **`package.json`**:
   - Update `"version"` field to `"${NEW_VERSION}"`.

4. **`src/cli.ts`**:
   - Update version string to `"${NEW_VERSION}"`.

5. **`docs/index.html`**:
   - Update the manual download link: `LeftOpen.zip (v${NEW_VERSION})`.

---

### Step 3: Compile and Package App Bundle

Build the release binaries and assemble the `.app` bundle:

```bash
# Build app bundle and embed CLI binary
LEFTOPEN_OUTPUT_DIR="$LEFTOPEN_OUTPUT_DIR" Scripts/build-app.sh
```

**Expected Result**:
- Application bundle generated at `dist/v${NEW_VERSION}/LeftOpen.app`.
- Both executables present in `Contents/MacOS`:
  - `LeftOpen.app/Contents/MacOS/LeftOpenApp` (GUI menu bar app)
  - `LeftOpen.app/Contents/MacOS/leftopen` (native CLI binary)

---

### Step 4: Sign, Notarize, and Staple

Sign all nested executables, sign the bundle with hardened runtime, submit to Apple Notary Service, and staple the notarization ticket:

```bash
LEFTOPEN_OUTPUT_DIR="$LEFTOPEN_OUTPUT_DIR" \
LEFTOPEN_APP_IDENTITY="$LEFTOPEN_APP_IDENTITY" \
LEFTOPEN_NOTARY_PROFILE="$LEFTOPEN_NOTARY_PROFILE" \
LEFTOPEN_BUNDLE_ID="$LEFTOPEN_BUNDLE_ID" \
Scripts/sign-and-notarize.sh
```

**Underlying Actions**:
1. Codesigns `${app_path}/Contents/MacOS/*` individually with `--options runtime --timestamp`.
2. Codesigns the top-level `LeftOpen.app`.
3. Submits `LeftOpen-notarization.zip` via `xcrun notarytool submit --keychain-profile leftopen-notary --wait`.
4. Staples ticket via `xcrun stapler staple LeftOpen.app`.
5. Validates Gatekeeper assessment via `spctl --assess --type execute -vv LeftOpen.app`.
6. Creates `dist/v${NEW_VERSION}/LeftOpen-release.zip`.

---

### Step 5: Prepare Release Artifact and Calculate Checksum

Copy the notarized release zip and generate its SHA-256 hash:

```bash
cp "${LEFTOPEN_OUTPUT_DIR}/LeftOpen-release.zip" LeftOpen.zip
SHA256_HASH=$(shasum -a 256 LeftOpen.zip | awk '{print $1}')
echo "SHA256: $SHA256_HASH"
```

---

### Step 6: Git Commit, Tag, and Push

Commit all version updates, tag the commit, and push to GitHub:

```bash
git add Package.swift README.md Resources/Info.plist Scripts/ docs/ package.json src/ Sources/
git commit -m "Release v${NEW_VERSION}: bump version and release build"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
git push origin main
git push origin "v${NEW_VERSION}"
```

---

### Step 7: Create GitHub Release

Publish the release on GitHub with the notarized zip attached:

```bash
gh release create "v${NEW_VERSION}" LeftOpen.zip \
  --title "v${NEW_VERSION} - Native leftopen CLI & App Bundle" \
  --notes "LeftOpen ${NEW_VERSION}

- Native leftopen CLI bundled inside application
- Signed with Developer ID and notarized by Apple
- Install via Homebrew: brew install --cask songhaifan/tap/leftopen"
```

---

### Step 8: Update Homebrew Tap

Update the Cask formula in `songhaifan/homebrew-tap`:

1. Clone the tap repository into a scratch directory:
   ```bash
   TAP_DIR="$(mktemp -d)/homebrew-tap"
   git clone https://github.com/SonghaiFan/homebrew-tap.git "$TAP_DIR"
   ```

2. Update `Casks/leftopen.rb` with the new version and SHA-256:
   ```ruby
   cask "leftopen" do
     version "<NEW_VERSION>"
     sha256 "<SHA256_HASH>"

     url "https://github.com/SonghaiFan/leftopen/releases/download/v#{version}/LeftOpen.zip"
     name "LeftOpen"
     desc "See what your tools left running on localhost"
     homepage "https://github.com/SonghaiFan/leftopen"

     depends_on macos: :sonoma

     app "LeftOpen.app"
     binary "#{appdir}/LeftOpen.app/Contents/MacOS/leftopen"

     zap trash: [
       "~/Library/Saved Application State/app.leftopen.mac.savedState",
     ]
   end
   ```

3. Commit and push the tap update:
   ```bash
   cd "$TAP_DIR"
   git add Casks/leftopen.rb
   git commit -m "leftopen ${NEW_VERSION}: release update"
   git push origin main
   ```

---

### Step 9: Post-Release Verification

Verify distribution channels and local tools:

1. **Verify Homebrew Cask**:
   ```bash
   brew update
   brew info --cask songhaifan/tap/leftopen
   brew fetch --cask songhaifan/tap/leftopen
   ```

2. **Verify GitHub Pages**:
   ```bash
   curl -sI https://songhaifan.github.io/leftopen/ | grep -E "HTTP/|last-modified"
   ```

3. **Update Local CLI**:
   ```bash
   cp .build/release/leftopen ~/.local/bin/leftopen
   chmod +x ~/.local/bin/leftopen
   leftopen -v
   leftopen list
   ```

---

## 4. Troubleshooting Reference

- **Notary Rejection**:
  - Run `xcrun notarytool log <SUBMISSION_ID> --keychain-profile leftopen-notary` to inspect Apple's diagnostic log.
  - Common cause: a nested executable in `Contents/MacOS/` was not individually signed before the outer `.app` was signed.
- **Homebrew Checksum Mismatch**:
  - Ensure `LeftOpen.zip` was generated from `LeftOpen-release.zip` *after* `xcrun stapler staple` completed.
  - Verify `shasum -a 256 LeftOpen.zip` matches the string in `Casks/leftopen.rb`.
- **Refusing to Overwrite Output Directory**:
  - `Scripts/build-app.sh` and `Scripts/sign-and-notarize.sh` prevent overwriting existing output folders. Always use a distinct directory (`dist/vX.Y.Z`).
