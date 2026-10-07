<div align="center">
  <img src="assets/logo.svg" alt="LeftOpen Logo" width="48" height="80" />
  <h1>LeftOpen</h1>
  <p><strong>Native macOS Menu Bar Port Manager &amp; CLI</strong></p>
  <p><em>See what your tools left running on localhost, identify projects, and gently close them.</em></p>
  <p>把那些虚掩着的门，轻轻关上。</p>

  <p>
    <a href="https://leftopen.songhai.site/"><img src="https://img.shields.io/badge/website-songhai.site-211811?style=flat-square" alt="Website" /></a>
    <a href="https://github.com/SonghaiFan/leftopen/releases/latest"><img src="https://img.shields.io/github/v/release/SonghaiFan/leftopen?color=black&style=flat-square" alt="Release" /></a>
    <a href="https://github.com/SonghaiFan/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-cask-211811?style=flat-square" alt="Homebrew Cask" /></a>
    <img src="https://img.shields.io/badge/macOS-14.0%2B-555555?style=flat-square" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Apple%20Notarized-Accepted-211811?style=flat-square" alt="Apple Notarized" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555?style=flat-square" alt="License: MIT" /></a>
  </p>

  <p><strong>English</strong> · <a href="README.zh-CN.md">中文</a></p>

  <br />
  <picture>
    <source srcset="assets/preview-dark.png" media="(prefers-color-scheme: dark)">
    <img src="assets/preview.png" alt="LeftOpen menu bar panel: closable ports first, apps and system services folded away" width="375" />
  </picture>
  <br /><br />
</div>

> When I have several coding agents working in parallel, dev servers and test runners keep starting up on different ports. By the end of the day there are always a few still running.
>
> Existing tools are either too much, or only tell you "port in use" without saying which process it is or which project it came from.
>
> So I made **LeftOpen**. It sits quietly in the menu bar and shows you the listening ports, the processes behind them and the projects they probably belong to. Once you've had a look, you close the ones you no longer need.
>
> *Close the doors that were left ajar, gently.*

---

## Installation

### Homebrew (recommended)

```bash
brew install --cask songhaifan/tap/leftopen
```

Supports Apple Silicon and Intel Macs running macOS Sonoma (14.0+). The app and bundled CLI are universal binaries, signed with a Developer ID and notarized by Apple.

### Manual download

Get `LeftOpen-release.zip` from [GitHub Releases](https://github.com/SonghaiFan/leftopen/releases/latest), unzip, and move `LeftOpen.app` to `/Applications`.

---

## Design & Features

- **Knows whose port it is.** Walks up from the process's working directory to `.git`, `package.json`, `pyproject.toml`, `Cargo.toml` or `go.mod`, or resolves the owning `.app`. Global npm packages, `python -m` modules and standalone services (Redis, Postgres, Ollama…) are named too, so you rarely see a bare `node` or `python`.
- **Real icons, nothing bundled.** Uses the `.app` icon when there is one; otherwise the icon the project or package ships itself (Tauri/Electron app icon, the favicon declared in `index.html`, `public/` conventions); otherwise the favicon served by the local server; otherwise a symbol.
- **Grouped by who started them.** Dev Servers (from a project, terminal, editor or agent), Background Services (launchd: brew services, login items), Apps and System. The group is also how a port is closed for good, and each one says so: SIGTERM for dev servers, `brew services stop …` for services launchd would restart, quitting the app for apps.
- **Closes gently first.** Sends `SIGTERM` and re-checks process identity. If a single-process close still leaves it listening after five seconds, that process is marked and the warning explains that closing it again within two minutes sends `SIGKILL`. The second click or swipe is the deliberate force-close action; existing safety protections and identity checks still apply.
- **Local vs LAN.** Tells apart ports bound to `127.0.0.1` from ones on `0.0.0.0` or a LAN address.
- **Nothing running in the background.** Native SwiftUI `MenuBarExtra`. No daemon, no Dock icon, no telemetry. The only request that leaves this Mac is a daily check of the latest GitHub release, which you can turn off in Settings.
- **Same engine in the terminal.** The app ships a `leftopen` CLI with identical inference and safety rules.

---

## Why LeftOpen? (Common Use Cases)

- **Fix "Port already in use" (`EADDRINUSE`)**: When your dev server fails because port 3000, 5173, or 8080 is blocked by a lingering process, LeftOpen shows you what's running and shuts it down gently—without restarting your terminal or machine.
- **Identify the project, not just a generic `node` or `python` PID**: Tools like `lsof -i` or `kill-port` only report raw PIDs or ambiguous process names. LeftOpen tracks the working directory and project root (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `.git`), giving you full context before taking action.
- **Spot accidental LAN exposure**: See at a glance whether a port is bound strictly to `127.0.0.1` (local only) or `0.0.0.0` (accessible to anyone on your local network/Wi-Fi).
- **Graceful SIGTERM vs. destructive `kill -9`**: Unlike blunt force-killing scripts, LeftOpen re-verifies PID and start time, shows sibling ports, and issues a standard `SIGTERM` so servers can clean up sockets, flush logs, and exit cleanly.

---

## CLI

Available in the terminal right after installing:

```bash
# List every listening port and its owner (or: leftopen list)
leftopen

# Explain one port
leftopen 3000

# Open http://localhost:3000 in the default browser
leftopen open 3000

# Close the process on a port (SIGTERM, asks first)
leftopen close 3000

# Structured JSON output
leftopen --json
```

Sample output:
```text
LEFT OPEN
26 listening ports · 17 processes · 1 projects · 8 LAN-visible

MY PROJECTS (2)
PORT    PID      OWNER          PROCESS    AGE      SCOPE
5173    76344    visdelta       node       2h       LOCAL
         ↳ ~/Documents/visdelta
5511    4999     visdelta       node       27m      LOCAL
         ↳ ~/Documents/visdelta

APPLICATIONS (16)
PORT    PID      OWNER          PROCESS    AGE      SCOPE
5000    696      ControlCenter  Control    3d       LAN
9222    36824    Google Chrome  Chrome     5h       LOCAL

SERVICES (3)
PORT    PID      OWNER          PROCESS    AGE      SCOPE
11434   911      Ollama         ollama     1d       LOCAL

LOCAL = this Mac only · LAN = may be reachable from your local network
```

---

## Development

Maintainers: [one-click releases](docs/releasing.md).

```bash
# Tests
swift test

# Build the app locally
LEFTOPEN_OUTPUT_DIR=dist/dev Scripts/build-app.sh
```

---

## License

[MIT License](LICENSE)


## Fixed project addresses

Complete **Settings → Projects → Local project addresses → Set up once** first. Then start your project normally and click **Enable fixed address** in its port details. LeftOpen bundles Portless and Node; no separate Portless installation or terminal commands are needed. New addresses use `https://myapp.localhost`. The Settings page explains why the first setup requests macOS authorization to trust a local CA, install a dedicated loopback service on port 443, and manage exact hosts entries. Later projects use that service without another prompt. Only the Settings setup/repair button requests authorization. Project actions direct you there if needed; background scans never request authorization. macOS can show separate administrator and certificate-trust dialogs during this one-time setup.

Previously enabled HTTP addresses keep working; **Settings → Projects → Local project addresses** completes the HTTPS upgrade. Keep LeftOpen open for observed services: mappings use short observation leases, expire when scans stop, and restore on launch. Disabling an address does not stop the project. The dedicated HTTPS service remains installed across app quits; Portless-started sessions retain their own lifecycle. Port 443 conflicts are reported without taking over another service. External Portless state and service labels are separate.

Saved projects appear as **Not running** with a **Start** button when an existing development script is available. This uses Portless's actual launcher: free-port allocation, framework arguments, project configuration, worktree naming, and workspace discovery. LeftOpen never reconstructs a startup command from process arguments or changes project files. Projects without a configured script offer **Open project** instead. Runtime/package-manager dependencies belonging to the project are still required.

LeftOpen verifies the project root, executable, working directory, hashed command identity and live listener before following port changes. Ambiguous or unrelated listeners are not forwarded. HTTPS-only upstreams and non-web ports cannot be enabled. A development server that rejects the hostname reports an inline error; project configuration is not edited automatically.

For agents and scripts, `leftopen url [name|port|path]` prints current verified addresses; add `--json` for structured output. `leftopen --json` includes `fixedURL` for matching services. Both read the same short-lived catalog as the app and recheck live listener identity. External addresses remain available under Address options.

The app includes Portless 0.15.7 (Apache-2.0) and Node 24.14.0 with their licenses. Builds verify pinned archive checksums and bundle both Mac architectures. Release signing must also sign the nested Node binaries with their JIT entitlement.

[Portless documentation](https://github.com/vercel-labs/portless)
