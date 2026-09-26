<div align="center">
  <img src="assets/logo.svg" alt="LeftOpen Logo" width="48" height="80" />
  <h1>LeftOpen</h1>
  <p><strong>Native macOS Menu Bar Port Manager &amp; CLI</strong></p>
  <p><em>See what your tools left running on localhost, identify projects, and gently close them.</em></p>
  <p>把那些虚掩着的门，轻轻关上。</p>

  <p>
    <a href="https://songhaifan.github.io/leftopen/"><img src="https://img.shields.io/badge/website-GitHub%20Pages-211811?style=flat-square" alt="Website" /></a>
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
- **Closes gently.** Shows the process's other ports before you confirm, re-checks PID and start time at the moment of closing, sends `SIGTERM` only. Never `SIGKILL`, never system processes.
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

```bash
# Tests
swift test

# Build the app locally
LEFTOPEN_OUTPUT_DIR=dist/dev Scripts/build-app.sh
```

---

## Windows port

A Windows port lives in [`windows/`](windows/README.md): a system-tray app plus a `leftopen` CLI that share one C# engine (`LeftOpen.Core`). It keeps the same philosophy and safety model — scan only when the panel opens, explainable ownership inference with confidence and reasons, and gentle close only (WM_CLOSE / console Ctrl+C / Ctrl+Break, never a force-kill).

```powershell
dotnet build windows\LeftOpen.sln
windows\src\LeftOpen.Tray\bin\Debug\net8.0-windows\LeftOpenApp.exe   # tray app
windows\src\LeftOpen.Cli\bin\Debug\net8.0-windows\leftopen.exe       # CLI
```

---

## License

[MIT License](LICENSE)
