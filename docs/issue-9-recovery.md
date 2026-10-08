# Fixed-address recovery: issue #9

Prepared against `2247666483acabbf000791937f1c8fb1645fa05b` (v0.5.2 source).
The owner authorized a beta for testing. A stable release and replying to #9
still require separate confirmation.

## Beta 2: authorization session correction

The running beta 1 was confirmed as 0.5.3 build 1008. Native authd logs at
21:32 on October 8 showed `trustd` denying `com.apple.trust-settings.admin`
with `-60007` (`errAuthorizationInteractionNotAllowed`). The state directories
were accessible; the current CA failed SSL trust verification.

Certificate trust now runs `/usr/bin/security` directly as the logged-in app user,
using that user's default keychain and SSL-only trust. It no longer uses an
elevated AppleScript or a terminal sudo fallback for certificate trust. The
Settings action remains the only caller; service installation retains its
separate administrator prompt. The user completes any native certificate prompt.
No terminal trust command was executed to pre-authorize this developer machine.

Beta 2 validation: 56 Swift tests passed, including argument boundaries, user-domain
SSL policy, default keychain parsing, and the observed interaction-denied error.
The full in-app authorization prompt still requires user testing; these tests
do not modify keychain trust or claim that GUI authorization was verified.

## Changes

- Repair only `~/Library/Application Support/LeftOpen` and its `Portless` child:
  accept root/current-user ownership, reject foreign owners and symbolic links,
  use directory descriptors for chown/chmod, and set these two directories to 0700.
  Do not change ancestors, certificate/private-key modes, unrelated descendants,
  or the root ownership requirements for the system runtime.
- Distinguish missing, inaccessible, unsafe, and readable certificate files with
  a real open operation. Missing/inaccessible certificates reach installation
  repair even when the service plist already exists. A readable, untrusted CA
  still uses the existing trust-only path.
- Enable only `system/app.leftopen.portless.proxy` before invoking upstream
  service installation, so a disabled label can be bootstrapped again.
  Existing port/PID/runtime identity checks run before this operation.
- Expose allowlisted failure stages and exit codes without copying raw subprocess
  output into the UI.
- Share eligibility checks between the swipe entry, detail view, and binding
  creation. Package-directory services such as global pi-web stay unsupported,
  with an explicit reason in details and a detail hint on the unavailable swipe.
  Scanner path exclusions remain unchanged. Supporting these services later
  needs a separate opt-in identity model and reconnect/restart policy.

## Verification (2026-10-08)

On the development Mac running macOS 26.6:

- `swift test`: 55 tests passed. Includes real filesystem ENOENT/EACCES cases,
  symbolic-link rejection, installation-vs-trust decisions, diagnostic filtering,
  and global-package eligibility.
- `LEFTOPEN_TEST_LAUNCHD=1 .build/portless-runtime/node-arm64 --test Tests/PortlessTests/*.test.mjs`:
  19 tests passed using the bundled Node runtime. Includes real HTTP, HTTPS,
  WebSocket routing, directory creation, targeted permission changes, and an
  isolated GUI-domain launchd agent: disabled bootstrap fails, enable then bootstrap succeeds.
  The agent is booted out at test completion. launchd may retain an enabled
  override for its unique test label; no production label is changed.
- `python3 -m unittest discover -s Tests/ReleaseTests`: 4 tests passed.
- `Scripts/build-app.sh`: local ad-hoc Universal app and CLI built and verified
  for arm64/x86_64. Bundled setup and setup-policy files match source.
- `git diff --check` and JavaScript syntax checks passed.

## Remaining manual acceptance

The root-owned metadata case uses an injected filesystem ownership boundary;
this run did not create/chown a real root-owned directory. The native launchd
test uses the GUI domain, not the production system daemon. No system CA trust,
production launchd service, or installed app was changed for testing.

On a disposable macOS 15.7.5 account, verify the full Settings flow with:

1. Fresh user directories; both become user-owned/0700 and HTTPS becomes ready.
2. A root-owned/0700 `LeftOpen` parent with existing CA files; setup repairs the
   two directories and can read the existing CA without broad permission changes.
3. A missing CA with an existing plist; setup proceeds to installation recovery.
4. A disabled, unloaded system service with a trusted CA; setup re-enables it
   and confirms HTTPS health.
5. A symlink, foreign owner, or unrelated 443 listener; setup refuses it.
6. Global pi-web: inspect the disabled detail explanation and original URL.

Full administrator-dialog recovery and the new UI wording have not been
visually verified in the reporter's macOS environment. These checks are not
replaced by the passing unit tests or local build.
