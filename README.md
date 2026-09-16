# LeftOpen

> See what your tools left running on localhost.

LeftOpen is a native macOS menu-bar app and a TypeScript CLI for understanding
local listening ports. Instead of showing only a raw `lsof` table, both collect
observable process facts and make conservative owner inferences from them.

## Installation

### Via Homebrew (Recommended)

Install the native macOS menu-bar app directly into `/Applications`:

```bash
brew install --cask SonghaiFan/tap/leftopen
```

> [!NOTE]
> If macOS Gatekeeper flags the app on first launch (since this open-source build is ad-hoc signed rather than signed with an Apple Developer ID), install with `--no-quarantine`:
> ```bash
> brew install --cask --no-quarantine SonghaiFan/tap/leftopen
> ```
> or run: `xattr -cr /Applications/LeftOpen.app`

### Direct Download

Download the latest `LeftOpen.zip` from [GitHub Releases](https://github.com/SonghaiFan/leftopen/releases/latest), unzip, and drag `LeftOpen.app` to your `/Applications` folder.

## Native menu-bar app

The Swift app requires macOS 14 or later. It uses SwiftUI `MenuBarExtra` with a
window-style panel and has no Dock icon. The status item shows the listening-port
count. Opening it shows a branded, grouped listener list with native search;
rows reserve symbols for unknown owners and LAN-facing bind addresses. Selecting
a row reveals process facts and an explicit Close review; owner-attribution
evidence is available on demand. It supports manual refresh (Command-R) and Escape to cancel the Close
review. It scans on launch, once per minute while running, and when the panel
opens; it does not run a network service.

```bash
swift test
Scripts/build-app.sh
open dist/LeftOpen.app
```

`Scripts/build-app.sh` builds a self-contained, host-architecture `.app` and
ad-hoc signs it for local development. It refuses to overwrite an existing
`LeftOpen.app`; choose a fresh `LEFTOPEN_OUTPUT_DIR` for another build. The Swift
scanner and Close implementation are independent of Node, so the app does not
need Node installed. The original TypeScript CLI remains available below.
In this workspace, the latest UI test build is `dist/process-port-hierarchy-ui/LeftOpen.app`;
earlier test bundles are retained rather than overwritten.

Close is never automatic: the panel previews one PID, its executable, start
time, and any other ports it listens on, then requires a separate confirmation.
The Swift core re-scans the port and process identity immediately before sending
SIGTERM. It refuses OS/app-owned processes, other users' processes, missing
identity evidence, and root operation. It never escalates to SIGKILL.

## Direct distribution

For distribution outside the Mac App Store, use a Developer ID Application
certificate, hardened-runtime signing, Apple's notarization service, and a
stapled ticket. The release script requires you to explicitly choose a stable
bundle ID, signing identity, and a `notarytool` Keychain profile; no credentials
are embedded in this repository.

```bash
LEFTOPEN_OUTPUT_DIR=/absolute/new/output \
LEFTOPEN_BUNDLE_ID=your.reverse.dns.id \
Scripts/build-app.sh

LEFTOPEN_OUTPUT_DIR=/absolute/new/output \
LEFTOPEN_BUNDLE_ID=your.reverse.dns.id \
LEFTOPEN_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
LEFTOPEN_NOTARY_PROFILE=your-keychain-profile \
Scripts/sign-and-notarize.sh
```

The script verifies the bundle ID and code signature, submits a zip to
`notarytool`, staples the ticket, checks Gatekeeper acceptance, and creates
`LeftOpen-release.zip`. It refuses to replace an existing zip. No Developer ID
signing or notarization has been performed on the local development build.
See Apple's [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
for certificate and `notarytool` profile setup. The current script builds only
the host CPU architecture, not a universal binary.

## TypeScript CLI

This prototype uses the native TypeScript support in recent Node.js releases and
has no third-party dependencies.

```bash
npm start
npm start -- 3000
npm start -- --json
npm start -- close 3000 --dry-run
npm start -- close 3000
```

To make the `leftopen` command available while working on the prototype:

```bash
npm link
leftopen
leftopen 3000
leftopen close 3000 --dry-run
leftopen close 3000
```

## What it shows

- TCP listening ports on macOS
- PID, parent PID/process chain, executable path, user, and working directory
- project roots evidenced by `.git`, `package.json`, `pyproject.toml`,
  `Cargo.toml`, or `go.mod`
- application names evidenced by macOS `.app` bundle paths
- system-service labels evidenced by operating-system executable locations
- whether a listener is local-only or potentially visible on the LAN
- merged IPv4/IPv6 addresses for the same PID and port
- explicit confidence and reason fields for every inferred owner

The JSON output separates `facts` from `inference`. Process names and paths are
reported as facts; they are never searched for a built-in list of product or
vendor keywords. If the available evidence does not establish an owner, LeftOpen
reports `Unknown`.

Project markers found in installed-software trees, app bundles, the user Library,
hidden per-user tool-data directories, caches, and dependency trees are ignored.
This prevents package metadata belonging to extensions or installed runtimes from
being presented as a user's project.

## Current boundary

Scanning remains read-only. `leftopen close <port>` is a separate, explicit
operation that gracefully terminates the single process listening on that port.
It sends `SIGTERM` to one PID, not to a port, parent process, or process tree.
If several PIDs share the port, specify `--pid <pid>` after inspecting them.
Use `--dry-run` to see the target without sending a signal, or `--yes` to
confirm non-interactively. The interactive command defaults to **No**.

Before signalling, LeftOpen requires the current user's UID, an executable
path, and a process start time. It re-scans the listener and compares those
facts after confirmation to reduce the risk of terminating a reused PID.
Application-owned processes and operating-system executable locations are
refused; running `close` as root is also refused. Closing a process may also
close its other listening ports, which are shown in the preview. LeftOpen waits
briefly and checks whether the port is
free; it never escalates to `SIGKILL` automatically. A service manager may
restart a stopped process and reoccupy the port.

The tool does not inspect ordinary browser history, run in the background, or
send telemetry.

Classification is evidence-based but still heuristic. Use `leftopen <port>` to
see the raw executable, CWD, parents, addresses, accepted marker or app bundle,
confidence, and inference reason.

The scanner currently depends on macOS `/usr/sbin/lsof`, `/bin/ps`, `.app` bundle
layout, and conventional macOS filesystem locations. Permissions can hide CWDs,
executable paths, or the process table; when parent evidence is unavailable the
CLI reports that limitation and keeps uncertain owners as `Unknown`. Reachability
is inferred only from the listener bind address—it does not test firewalls,
containers, virtual machines, reverse proxies, or actual network connectivity.
The `close` command additionally depends on `/bin/ps` for a start-time check
and refuses to act when that check is unavailable. There remains a narrow race
between the final identity check and signalling the PID; macOS does not expose
a PID-bound signal handle through this prototype.
Without explicit metadata, LeftOpen also cannot reliably tell whether an
application is a browser, AI tool, editor, or another kind of app, so it does not
guess those semantic subcategories from names.

## Test

```bash
npm test
```
