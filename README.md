<div align="center">
  <img src="assets/logo.svg" alt="LeftOpen Logo" width="48" height="80" />
  <h1>LeftOpen</h1>
  <p>把那些虚掩着的门，轻轻关上。</p>
  <p><em>See what your tools left running on localhost, and gently close them.</em></p>

  <p>
    <a href="https://songhaifan.github.io/leftopen/"><img src="https://img.shields.io/badge/website-GitHub%20Pages-211811?style=flat-square" alt="Website" /></a>
    <a href="https://github.com/SonghaiFan/leftopen/releases/latest"><img src="https://img.shields.io/github/v/release/SonghaiFan/leftopen?color=black&style=flat-square" alt="Release" /></a>
    <a href="https://github.com/SonghaiFan/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-cask-211811?style=flat-square" alt="Homebrew Cask" /></a>
    <img src="https://img.shields.io/badge/macOS-14.0%2B-555555?style=flat-square" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Apple%20Notarized-Accepted-211811?style=flat-square" alt="Apple Notarized" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555?style=flat-square" alt="License: MIT" /></a>
  </p>

  <br />
  <picture>
    <source srcset="assets/preview-dark.png" media="(prefers-color-scheme: dark)">
    <img src="assets/preview.png" alt="LeftOpen menu bar panel: closable ports first, apps and system services folded away" width="375" />
  </picture>
  <br /><br />
</div>

> 当我并行让多个 agent 写代码时，开发服务器和测试服务会不断启动，监听不同的端口。忙完一天，电脑里往往留下不少还开着的服务。
>
> 现有工具要么太复杂，要么只能告诉你“端口被占用”，却说不清它到底属于哪个进程、可能来自哪个项目。
>
> 所以我做了 **LeftOpen**。它安静地待在菜单栏里，帮你一眼看清正在监听的端口、对应的进程，以及可能关联的项目。确认之后，你可以关闭那些不再需要的服务。
>
> *把那些虚掩着的门，轻轻关上。*

---

## 安装 (Installation)

### Homebrew (推荐)

```bash
brew install --cask songhaifan/tap/leftopen
```

已通过 Apple 官方公证（Notarized），在 macOS Sonoma (14.0+) 上下载即可直接打开。

### 手动下载

前往 [GitHub Releases](https://github.com/SonghaiFan/leftopen/releases/latest) 下载 `LeftOpen.zip`，解压后将 `LeftOpen.app` 移至 `/Applications`。

---

## Design & Features

- **Knows whose port it is.** Walks up from the process's working directory to `.git`, `package.json`, `pyproject.toml`, `Cargo.toml` or `go.mod`, or resolves the owning `.app`. Global npm packages, `python -m` modules and standalone services (Redis, Postgres, Ollama…) are named too, so you rarely see a bare `node` or `python`.
- **Real icons, nothing bundled.** Uses the `.app` icon when there is one; otherwise the icon the project or package ships itself (Tauri/Electron app icon, the favicon declared in `index.html`, `public/` conventions); otherwise the favicon served by the local server; otherwise a symbol.
- **Closable first.** Ports you can close come first; apps and system services are folded away. The menu bar icon is an open or closed door, and every row shows how long the process has been running.
- **Closes gently.** Shows the process's other ports before you confirm, re-checks PID and start time at the moment of closing, sends `SIGTERM` only. Never `SIGKILL`, never system processes.
- **Local vs LAN.** Tells apart ports bound to `127.0.0.1` from ones on `0.0.0.0` or a LAN address.
- **Nothing running in the background.** Native SwiftUI `MenuBarExtra`. No daemon, no Dock icon, no telemetry.
- **Same engine in the terminal.** The app ships a `leftopen` CLI with identical inference and safety rules.

---

## 命令行 (CLI)

安装后即可在终端直接运行：

```bash
# 查看所有监听端口与归属（或 leftopen list）
leftopen

# 查看指定端口详情
leftopen 3000

# 在默认浏览器打开 http://localhost:3000
leftopen open 3000

# 安全关闭指定端口（SIGTERM，提示确认）
leftopen close 3000

# 结构化 JSON 输出
leftopen --json
```

CLI 输出示例：
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

## 构建与测试 (Development)

```bash
# 运行原生测试
swift test

# 运行 CLI 测试
npm test

# 本地编译 App
LEFTOPEN_OUTPUT_DIR=dist/dev Scripts/build-app.sh
```

---

## 许可证 (License)

[MIT License](LICENSE)
