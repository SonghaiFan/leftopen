# Release LeftOpen

After merging changes into `main`, open **Actions → Release → Run workflow**,
keep the branch on `main`, and enter the new version (for example, `0.4.1`).
Use a version newer than the current release. Do not create a tag or Release first.

The workflow tests, builds Universal binaries, signs and notarizes the app,
verifies the final ZIP, publishes a Release with generated notes, and updates
Homebrew's version and checksum. Notes can be edited on GitHub afterward.
Runner availability and Apple notarization affect elapsed time.

For a beta, set `prerelease` to true and choose `beta_number` (starting at 1).
Version `0.5.3` with beta number `1` publishes `v0.5.3-beta.1`, explicitly marked
as a prerelease and not Latest. Homebrew is skipped and the app's stable update
checker remains on the previous stable release. The app/CLI version remains the
numeric `0.5.3`; its increasing build number distinguishes beta builds. Download
the beta from its explicit release page. Increase the beta number for a new beta;
do not overwrite a published archive. Stable releases use the default inputs.

## One-time configuration

In **Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of a password-protected `.p12` export of the existing Developer ID Application certificate **and private key**. |
| `APPLE_CERTIFICATE_PASSWORD` | The `.p12` export password. |
| `APPLE_SIGNING_IDENTITY` | The existing full `Developer ID Application: … (TEAMID)` identity. |
| `APPLE_ID` | Apple account used for notarization. |
| `APPLE_TEAM_ID` | Developer Team ID. |
| `APPLE_APP_PASSWORD` | An Apple app-specific password for notarization. |
| `HOMEBREW_TAP_TOKEN` | A fine-grained GitHub token for `SonghaiFan/homebrew-tap`, with **Contents: read and write** and permission to push to `main`. |

Use the existing Developer ID and bundle identifier (`app.leftopen.mac`). Keep
signing exports outside the repository; never paste credentials into source,
logs, issues, or chat. GitHub supplies the release job's `GITHUB_TOKEN` automatically.
The tap needs its own token because it is another repository.

Signing credentials are installed into a temporary hosted-runner keychain and
removed by an `always()` cleanup step. No always-on local machine is needed.

## Versioning and retries

- The version is applied to App and CLI in the temporary checkout; no version-bump
  commit is pushed to `main`. Source literals remain development defaults.
- The build number is `1000 + github.run_number`. Retries retain it. Preserve
  this workflow's numbering; if replacing it, choose an offset greater than the
  last published build number.
- The tag identifies the exact source commit. Its release metadata is reproduced
  with `Scripts/prepare-release.py`, the workflow input and recorded build number.
- Assets are uploaded to a draft before publication. The same run can retry a
  failed draft upload; published releases are never overwritten.
- If Homebrew fails after publication, select **Re-run failed jobs**. The published
  Release remains available. Do not create a new run for the same version.
- Releases are serialized. GitHub can replace an older pending run when another
  is queued, so wait for completion before requesting another version.

## App updates

Installed apps still discover releases through the current GitHub update checker.
This workflow does not add Sparkle or automatic installation. Sparkle requires
app integration and an EdDSA-signed appcast, which can later be generated from
the notarized ZIP in this workflow.

## Validation

CI and release preflight execute the hardened Node runtime and bundled Portless
on both native Intel and Apple Silicon runners. Intel Node alone receives
`allow-unsigned-executable-memory`; the app and ARM Node do not. Both local and
Developer ID builds use `Scripts/sign-portless-runtime.sh`. Runtime smoke tests
also run after Developer ID signing and after extracting the final archive.
They execute JavaScript, not just `node --version`, which skips V8 initialization.
For a local cross-architecture check on Apple Silicon with Rosetta installed, run
`python3 Scripts/verify-portless-runtime.py <app>/Contents/Resources/Portless --architecture x64`.
These non-privileged checks do not install launchd services or alter certificate
trust; the app's first-run authorization still needs interactive device testing.

Run `python3 -m unittest discover -s Tests/ReleaseTests` for version validation
and `actionlint .github/workflows/release.yml` for workflow checks. The first
configured Actions run must still verify the real hosted runner, Apple credentials,
notarization and tap push permissions.
