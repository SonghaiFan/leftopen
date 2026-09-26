# LeftOpen Release & Publish Workflow

This document defines the end-to-end publishing workflow for LeftOpen. It is designed for autonomous execution by AI agents and maintainers to build, sign, notarize, release, and distribute new versions of LeftOpen.

---

## 1. Prerequisites and Environment

Ensure the following tools, credentials, and permissions are available before initiating a release:

- **Operating System**: macOS Sonoma 14.0 or later on an Apple Silicon or Intel Mac.
- **Build Tools**:
  - Xcode Command Line Tools (`swift`, `codesign`, `xcrun`, `ditto`, `plutil`, `lipo`) with support for both `arm64` and `x86_64` macOS targets.
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
export NEW_VERSION="0.3.3"          # Semantic version (X.Y.Z)
export NEW_BUILD="10"                # Monotonically increasing build integer
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

3. **`README.md`, `README.zh-CN.md`, and `docs/index.html`**:
   - Keep installation requirements current. The manual download links use GitHub's latest release, so they do not require a version bump.

---

### Step 3: Compile and Package App Bundle

Build the release binaries and assemble the `.app` bundle:

```bash
# Build universal app and CLI binaries and assemble the bundle
LEFTOPEN_OUTPUT_DIR="$LEFTOPEN_OUTPUT_DIR" Scripts/build-app.sh
```

**Expected Result**:
- Application bundle generated at `dist/v${NEW_VERSION}/LeftOpen.app`.
- Both executables present in `Contents/MacOS`:
  - `LeftOpen.app/Contents/MacOS/LeftOpenApp` (GUI menu bar app)
  - `LeftOpen.app/Contents/MacOS/leftopen` (native CLI binary)
- Both executables contain `arm64` and `x86_64` slices, supporting Apple Silicon and Intel Macs on macOS 14.0 or later. Verify before signing:

  ```bash
  Scripts/verify-universal-app.sh "${LEFTOPEN_OUTPUT_DIR}/LeftOpen.app"
  ```

  The build and signing scripts also run this check automatically and reject an app missing either architecture or executable.

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
1. Codesigns the bundled `${app_path}/Contents/MacOS/leftopen` CLI with `--options runtime --timestamp`.
2. Codesigns the top-level `LeftOpen.app` and its main executable with `--options runtime --timestamp`.
3. Submits `LeftOpen-notarization.zip` via `xcrun notarytool submit --keychain-profile leftopen-notary --wait`.
4. Staples ticket via `xcrun stapler staple LeftOpen.app`.
5. Validates Gatekeeper assessment via `spctl --assess --type execute -vv LeftOpen.app`.
6. Creates `dist/v${NEW_VERSION}/LeftOpen-release.zip`.

---

### Step 5: Prepare Release Artifact and Calculate Checksum

The notarized `LeftOpen-release.zip` is the release artifact. Publish it under this exact name: the Homebrew cask downloads `LeftOpen-release.zip`. Generate its SHA-256 hash:

```bash
RELEASE_ZIP="${LEFTOPEN_OUTPUT_DIR}/LeftOpen-release.zip"
SHA256_HASH=$(shasum -a 256 "$RELEASE_ZIP" | awk '{print $1}')
echo "SHA256: $SHA256_HASH"
```

---

### Step 6: Git Commit, Tag, and Push

Commit all version updates, tag the commit, and push to GitHub:

Review `git status` first, then stage everything, including tests, docs and deletions:

```bash
git status --short
git add -A
git commit -m "Release v${NEW_VERSION}"
git tag -a "v${NEW_VERSION}" -m "Release v${NEW_VERSION}"
git push origin main
git push origin "v${NEW_VERSION}"
```

---

### Step 7: Create GitHub Release

Publish the release on GitHub with the notarized zip attached:

```bash
gh release create "v${NEW_VERSION}" "$RELEASE_ZIP" \
  --title "LeftOpen v${NEW_VERSION}" \
  --notes "LeftOpen ${NEW_VERSION}

- Universal app and bundled CLI for Apple Silicon and Intel Macs (macOS 14+)
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

     url "https://github.com/SonghaiFan/leftopen/releases/download/v#{version}/LeftOpen-release.zip"
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

3. **Verify Published Architectures**:
   - Download the published `LeftOpen-release.zip`, extract it into a new directory, and run `Scripts/verify-universal-app.sh /path/to/extracted/LeftOpen.app` to check both executables.
   - Test the app and CLI on Apple Silicon and Intel Macs when available. Record hardware coverage separately from build and signing verification; an `x86_64` run under Rosetta is useful but does not replace an Intel hardware check.

4. **Upgrade the Local Install**:
   The cask links the bundled CLI into Homebrew's `bin`, so upgrading the cask updates both the app and `leftopen`. Do not keep a separate copy in `~/.local/bin`: it would shadow the Homebrew CLI and go stale.
   ```bash
   brew upgrade --cask songhaifan/tap/leftopen
   leftopen -v
   leftopen list
   ```

---

## 4. Troubleshooting Reference

- **Notary Rejection**:
  - Run `xcrun notarytool log <SUBMISSION_ID> --keychain-profile leftopen-notary` to inspect Apple's diagnostic log.
  - Common cause: a nested executable in `Contents/MacOS/` was not individually signed before the outer `.app` was signed.
- **Homebrew Checksum Mismatch**:
  - Ensure `LeftOpen-release.zip` was created *after* `xcrun stapler staple` completed (the signing script does this).
  - Verify `shasum -a 256 "${LEFTOPEN_OUTPUT_DIR}/LeftOpen-release.zip"` matches the string in `Casks/leftopen.rb`.
- **Homebrew Download 404**:
  - The GitHub release must have an asset named exactly `LeftOpen-release.zip`, as in the cask `url`.
- **Refusing to Overwrite Output Directory**:
  - `Scripts/build-app.sh` and `Scripts/sign-and-notarize.sh` prevent overwriting existing output folders. Always use a distinct directory (`dist/vX.Y.Z`).
