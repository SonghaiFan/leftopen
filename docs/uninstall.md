# Complete uninstall

In LeftOpen, open **Settings → About → Uninstall LeftOpen…**. Confirm once and
complete any macOS authorization prompts. The action removes the login item,
the LeftOpen address daemon and its runtime, the exact local CA from the current
user's keychains and the system keychain, LeftOpen hosts entries, saved addresses,
settings and caches. Project files and unrelated Portless installations remain.

Downloaded apps are moved to Trash after cleanup succeeds. For Homebrew installs,
LeftOpen runs `brew uninstall --cask --zap songhaifan/tap/leftopen` after cleanup,
with dependency autoremove disabled, so Homebrew removes the CLI link and its
Caskroom record. This requires the installed app and bundled runtime; development
executables cannot uninstall a production app.

Authorization cancellation or cleanup failures leave the app available for retry.
Some earlier steps (such as login item or user certificate removal) may already
have completed. A retry accepts missing entries but fails on inaccessible keychains,
unexpected service ownership, symlinks, or edited hosts blocks. Unreadable or unsafe
CA files still stop cleanup. A missing CA does not block removal of a verified
LeftOpen daemon and files, but NO keychain entry is deleted in that case. Native
uninstall shows a warning before app removal; Homebrew prints a warning. Neither
path claims that unidentified certificates were removed.

If the original CA file was deleted, recreating a new CA cannot identify the old
keychain entry. That orphan needs manual review; the uninstaller reports the
problem rather than claiming it removed an unidentified certificate. Projects
started through LeftOpen must be stopped before uninstalling so their wrappers
cannot recreate the deleted address state.

## Interrupted-install recovery (0.5.5)

Setup and uninstall validate the root-owned plist, the loaded launchd job's full
arguments and user-state path, and its actual root process executable. A missing
`proxy.pid`, runtime directory or CA no longer prevents recognition of LeftOpen's
own running service. Setup also requires every HTTPS listener to belong to that
verified PID before stopping it; it never kills a PID from user state. The job is
rechecked immediately before bootout. Unknown or changed identities fail closed.
After one bootout attempt, setup and uninstall poll for confirmed launchd absence
for up to five seconds of retry delays. A nonzero bootout result is not treated as
failure if the job is demonstrably absent. A still-loaded job and an unsuccessful
state query have distinct errors; neither allows subsequent file deletion.
Setup rebuilds the service and missing certificate through the app's existing
authorization flow. If the original CA is lost, old keychain entries cannot be
identified from a new CA and may still need review.

## Copyable diagnostics (0.5.5)

Login-item cleanup treats the framework's `notRegistered` and `notFound` states
as already absent. Enabled or approval-pending items are unregistered and their
final state is verified. A racing `kSMErrorJobNotFound` is accepted only in the
ServiceManagement error domain and with an absent final state; generic code 1,
signature/authorization failures and unknown states still stop cleanup before
certificate or daemon mutation. This policy is shared by GUI and Homebrew cleanup.

Setup and uninstall failures retain the short explanation and add an expandable
Technical details / 技术详情 section with Copy diagnostic info / 复制诊断信息.
Reports include a UTC timestamp, app version/build, macOS version, executing
architecture, failure stage/code, command exit status or termination signal, and
available numeric system errors. Structured helper records distinguish bootout
from subsequent state verification. Homebrew cleanup failures print the same safe
report. No report is uploaded automatically or persisted to a log file.

Raw command arguments/output, environment, personal paths and certificate material
are not copied. Only bounded allowlisted helper fields and numeric system codes
survive parsing. Unexpected errors retain only an allowlisted NSError domain and
its numeric code. A new attempt clears the preceding diagnostic snapshot.
ServiceManagement domains and up to two underlying numeric errors are preserved,
without localized descriptions or user-info payloads. Login-item failures include
before/after status values and use `uninstall.loginItem`; certificate, user-data,
preferences, command-launch and app-removal failures have separate stages.

## Distribution boundary

The uninstall action is explicit and is never called by the updater, app startup,
Homebrew upgrade, or reinstall. Starting with the 0.5.4 cask, standalone
`brew uninstall leftopen` (also `--cask` or `--zap`) runs the same cleaner before
Homebrew removes the app and CLI. Quit LeftOpen and stop projects launched by it
first. Cleanup refuses a running app or bundled project runtime instead of killing
projects. macOS authorization can still be required; cancellation/failure aborts
removal, leaving the app for retry. Do not use `sudo brew`.

The tap's preflight checks Homebrew's normalized `running_command_with_args`; only explicit
`uninstall` runs cleanup. Upgrade, reinstall, install and automatic dependency
removal do not erase user state. The cleanup-only app entry never starts SwiftUI
or calls brew. The native app performs cleanup itself and passes a private
`LEFTOPEN_UNINSTALL_CLEANED=1` environment flag only to its brew child to prevent
duplicate cleanup. Do not set this flag in your shell.

Homebrew uses the cask metadata saved at installation time. Existing 0.5.3 and
older installations need `brew upgrade --cask songhaifan/tap/leftopen` to receive
the new hook; `brew update` alone cannot retrofit their uninstall receipt.
The released cask is generated from `Resources/Homebrew/leftopen.rb` with the
verified release version and checksum, so later releases preserve the hook.
Dragging the app to Trash also does not invoke the cleaner. No watcher is installed.

## Validation

`node --test Tests/PortlessTests/*.test.mjs` covers exact daemon ownership, host
preservation, malformed markers, exact certificate deletion, cancellation/keychain
errors, filesystem links, another owner and refusal of non-root execution.
`ruby Tests/HomebrewTests/uninstall_test.rb` covers hook dispatch, preservation
during upgrade/reinstall, native handoff, missing helper and cleanup failures.
Swift tests cover early argument dispatch and refusal of orphaned app runtimes.
The Swift package and universal app build validate native integration.
`orphan-recovery.test.mjs` executes the actual setup/uninstall entrypoints with
virtual filesystem, network and command boundaries: missing runtime/PID/CA with
a live daemon, foreign listeners/users, changed PIDs, missing or unsafe plist,
loaded-state mismatch, and service-stop failures. These do not modify host state.
It also covers delayed unregister, nonzero bootout followed by confirmed absence,
pending shutdown and failed verification. `FailureDiagnosticsTests` covers
redaction, malformed records, numeric errors, signal classification and size limits.
Run `zsh Tests/DiagnosticsUITests/run.sh` for the standalone native disclosure/copy
fixture. It uses a private pasteboard and does not start LeftOpen's services.
`LoginItemCleanupTests` exercises absence, repeated cleanup, registration races,
authorization/signature failures, domain matching and final-state verification
using injected operations. A native status-only test checks an unregistered test
host without invoking the real unregister API.

Live destructive removal from real user/system keychains, macOS authorization
dialogs, login item unregister, Homebrew removal and final app trashing still need
an end-to-end run on a disposable macOS account before release. Policy tests do
not establish those behaviors as verified.
