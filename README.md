<div align="center">
  <img src="assets/logo.svg" alt="LeftOpen Logo" width="56" height="95" />
  <h1>LeftOpen</h1>
  <p><strong>把那些虚掩着的门，轻轻关上。</strong></p>
  <p><em>See what your tools left running on localhost, and gently close them.</em></p>

  <p>
    <a href="https://songhaifan.github.io/leftopen/"><img src="https://img.shields.io/badge/website-GitHub%20Pages-211811?style=flat-square" alt="Website" /></a>
    <a href="https://github.com/SonghaiFan/leftopen/releases/latest"><img src="https://img.shields.io/github/v/release/SonghaiFan/leftopen?color=black&style=flat-square" alt="Release" /></a>
    <a href="https://github.com/SonghaiFan/homebrew-tap"><img src="https://img.shields.io/badge/homebrew-cask-DE8500?style=flat-square" alt="Homebrew Cask" /></a>
    <img src="https://img.shields.io/badge/macOS-14.0%2B%20(Sonoma)-007AFF?style=flat-square" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Apple%20Notarized-Accepted-2E7D32?style=flat-square" alt="Apple Notarized" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-5F6168?style=flat-square" alt="License: MIT" /></a>
  </p>

  <br />
  <img src="assets/preview.jpg" alt="LeftOpen macOS Menu Bar App Preview" width="720" style="border-radius: 14px; box-shadow: 0 16px 40px rgba(0,0,0,0.12);" />
  <br /><br />
</div>

> 当我并行让多个 agent 写代码时，开发服务器和测试服务会不断启动，监听不同的端口。忙完一天，电脑里往往留下不少还开着的服务。
> 
> 问题是：现有工具要么太复杂，要么只能告诉你“端口被占用”，却说不清它到底属于哪个进程、可能来自哪个项目。
> 
> 所以我做了 **LeftOpen**。
> 它安静地待在 menu bar 里，帮你一眼看清正在监听的端口、对应的进程，以及可能关联的项目。确认之后，你可以关闭那些不再需要的服务。
> 
> *把那些虚掩着的门，轻轻关上。*

<details>
<summary><em>Read in English</em></summary>

> When running multiple AI agents coding in parallel, local dev servers and test suites spin up continuously across random ports. At the end of a long day, the system is left running dozens of forgotten background processes.
> 
> Existing tools are either far too heavyweight or only spit out "port is occupied" without telling you what process or workspace project actually owns it.
> 
> That's why I built **LeftOpen**.
> It sits quietly in your macOS menu bar, giving you an instant, trustworthy view of active ports, their processes, and inferred project roots. Once reviewed, you can gracefully close what you don't need.
> 
> *Gently closing the doors left ajar.*

</details>

<br />

**LeftOpen** 是一个原生 macOS 菜单栏应用与命令行工具（TypeScript CLI），用于洞察正在监听本机的各类服务端口。

它并不只是简单地输出一份生硬的 `lsof` 表格，而是收集进程相关的**客观事实**（工作目录、Git 仓库、`package.json`、`pyproject.toml`、macOS `.app` Bundle），据此对进程所属的项目或应用做出**严谨、克制的归属推断**，并提供安全的单键确认关闭体验。

---

## ⚡ 安装与使用 (Installation)

### 方式一：通过 Homebrew 安装（推荐）

直接将已通过 Apple 官方公证的原生应用安装至 `/Applications`：

```bash
brew install --cask SonghaiFan/tap/leftopen
```

> **注意**：应用由 Apple 官方公证（Notarized），在 macOS Sonoma (14.0+) 上下载后可直接双击运行，无需处理 Gatekeeper 拦截。

### 方式二：直接下载发布包

前往 [**GitHub Releases**](https://github.com/SonghaiFan/leftopen/releases/latest) 下载最新的 `LeftOpen.zip`，解压后将 `LeftOpen.app` 拖入 `/Applications` 文件夹。

---

## ✨ 核心特性 (Features)

- 🔍 **上下文感知的项目推断**：自动定位由 `.git`、`package.json`、`pyproject.toml`、`Cargo.toml` 或 `go.mod` 证明的真实项目，告别千篇一律的 `node` 或 `python`。
- 🛡️ **克制、温和的关闭体验**：
  - 关闭前自动完整预览该 PID 占用的所有其它关联端口。
  - 关闭前夕毫秒级二次核验 PID、启动时间与进程身份，防范 PID 重用误杀。
  - 仅发送温和的 `SIGTERM` 请求优雅退出，绝不在后台擅自升级为暴力 `SIGKILL`。
  - 严正拒绝关闭操作系统内核服务、已安装的应用软件或属于其他用户的进程。
- 🌐 **LAN 局域网暴露警示**：清晰区分绑定到回环地址（`127.0.0.1`，仅限本机）与暴露到局域网（`0.0.0.0` / LAN IP）的端口，防范接口意外暴露。
- 🍃 **极致轻量原生体验**：采用纯原生 SwiftUI `MenuBarExtra`（Window 风格面板），无 Dock 栏驻留，无后台网络守护进程，常驻菜单栏即点即开。
- ⌨️ **双重接口支持**：除了菜单栏 UI，还提供零外部依赖的纯 TypeScript 终端 CLI。

---

## 💻 命令行 CLI (TypeScript CLI)

LeftOpen CLI 利用了最新 Node.js 的原生 TypeScript 支持，**零第三方依赖**。

```bash
# 扫描并输出所有打开的端口及归属
npm start

# 查看特定端口（如 3000 或 5173）
npm start -- 3000

# 纯 JSON 结构化输出（事实与推断分离）
npm start -- --json

# 预览关闭端口（Dry run，不真正发信号）
npm start -- close 3000 --dry-run

# 交互式安全关闭端口（默认选择 No）
npm start -- close 3000
```

全局链接命令：
```bash
npm link
leftopen
leftopen 3000
```

### CLI 输出示例

```text
LEFT OPEN
26 listening ports · 17 processes · 1 projects · 8 LAN-visible

MY PROJECTS (2)
PORT    PID      OWNER          PROCESS    SCOPE
5173    76344    visdelta       node       LOCAL
         ↳ ~/Documents/visdelta
5511    4999     visdelta       node       LOCAL
         ↳ ~/Documents/visdelta

APPLICATIONS (16)
PORT    PID      OWNER          PROCESS    SCOPE
5000    696      ControlCenter  Control    LAN
9222    36824    Google Chrome  Chrome     LOCAL

SYSTEM SERVICES (3)
PORT    PID      OWNER          PROCESS    SCOPE
49152   680      rapportd       rapportd   LAN

LOCAL = this Mac only · LAN = may be reachable from your local network
```

---

## 🔒 安全准则与设计边界 (Security & Boundary)

1. **事实优先，绝无关键字猜测**：进程名、路径只作为事实记录，绝不在二进制内部内置诸如产品或厂商关键字列表去胡乱猜测。证据不足时，明确归类为 `Unknown`。
2. **过滤伪项目标记**：自动忽略用户 Library、开发工具隐藏目录、缓存目录以及 `node_modules` 内部的 package.json，避免将扩展或运行时的元数据误报为用户的项目。
3. **只读扫描**：扫描过程纯粹只读，不启动后台网络常驻进程，不收集任何数据，无遥测（No Telemetry）。
4. **最小化介入**：关闭操作以 PID 为唯一目标，不擅自向端口广播、也不递归 Kill 整个进程树。

---

## 🛠️ 本地构建与测试 (Development)

### 运行测试
```bash
# 运行 Swift 原生测试
swift test

# 运行 TypeScript CLI 测试
npm test
```

### 本地编译 macOS App
```bash
# 编译并生成临时本地开发 App
LEFTOPEN_OUTPUT_DIR=dist/dev Scripts/build-app.sh
open dist/dev/LeftOpen.app
```

---

## 📄 许可证 (License)

本项目采用 [MIT License](LICENSE) 开源。欢迎 Issue 与 PR！
