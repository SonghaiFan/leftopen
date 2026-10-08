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
unexpected service ownership, symlinks, or edited hosts blocks. Missing or unreadable
CA files prevent automatic certificate cleanup: the uninstaller never deletes
certificates merely by the shared “Portless” common name.

If the original CA file was deleted, recreating a new CA cannot identify the old
keychain entry. That orphan needs manual review; the uninstaller reports the
problem rather than claiming it removed an unidentified certificate. Projects
started through LeftOpen must be stopped before uninstalling so their wrappers
cannot recreate the deleted address state.

## Distribution boundary

The uninstall action is explicit and is never called by the updater, app startup,
Homebrew upgrade, or reinstall. A standalone `brew uninstall` currently does **not**
call this cleaner: the separate Homebrew tap needs a reviewed integration that
distinguishes final removal from upgrade/reinstall before adding such a hook.
Dragging the app to Trash also does not invoke the cleaner. No watcher is installed.

## Validation

`node --test Tests/PortlessTests/*.test.mjs` covers exact daemon ownership, host
preservation, malformed markers, exact certificate deletion, cancellation/keychain
errors, filesystem links, another owner and refusal of non-root execution.
The Swift package and universal app build validate native integration.

Live destructive removal from real user/system keychains, macOS authorization
dialogs, login item unregister, Homebrew removal and final app trashing still need
an end-to-end run on a disposable macOS account before release. Policy tests do
not establish those behaviors as verified.
