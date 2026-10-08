# LeftOpen (Windows)

> 把那些虚掩着的门，轻轻关上。

LeftOpen 是一个 Windows 系统托盘应用 + 命令行工具，用来**看清 localhost 上还有哪些进程在监听，并把不再需要的温和地关掉**。

它是 [SonghaiFan/leftopen](https://github.com/SonghaiFan/leftopen)（macOS 菜单栏应用）的 Windows 移植版：同一套理念、同一套安全规则、同样的“按需扫描、不做驻留”的行为，只是把菜单栏换成了系统托盘，把 `lsof`/`ps` 换成了 Windows 原生 API。

## 它解决什么问题

同时开几个编码代理、跑一堆 dev server 时，一天下来总有 `node`/`python` 还挂在 5173、8000、3000 上。Windows 自带的 `netstat` 只告诉你“端口被占用”，不告诉你**是哪个进程、属于哪个项目**。

LeftOpen 做三件事：

1. **端口归属**：从进程的工作目录向上找 `.git` / `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod`，把监听者归类为**我的项目 / 应用 / 系统服务 / 未知**，并给出判定依据（confidence + reason）。
2. **一眼看清**：托盘图标是一扇门（有遗留进程时门是开的），点开面板就是分组列表——端口、进程、运行时长、是否局域网可见。
3. **温和关闭**：关闭前展示完整信息并要求二次确认；只发送“温和”信号，**绝不强杀**；关不掉就如实告诉你。

## 安装与构建

需要 [.NET 8 SDK](https://dotnet.microsoft.com/download)（`winget install Microsoft.DotNet.SDK.8`）。

```powershell
# 开发构建
dotnet build LeftOpen.sln

# 运行
src\LeftOpen.Tray\bin\Debug\net8.0-windows\LeftOpenApp.exe     # 托盘应用
src\LeftOpen.Cli\bin\Debug\net8.0-windows\leftopen.exe         # 命令行

# 发布（默认框架依赖单文件，约 700 KB；需要 .NET 8 运行时）
powershell -File Scripts\publish.ps1

# 发布自包含版本（目标机器无需安装 .NET，托盘约 158 MB——WinForms 不支持裁剪）
powershell -File Scripts\publish.ps1 -SelfContained
```

## 托盘应用

- 启动后只驻留一个托盘图标（门）：**不扫描、不轮询、无守护进程**。
- 点击图标 → 弹出面板 → **此刻才扫描一次**；再次点击或点击别处自动收起。
- 面板分组：`我的项目` / `其他进程` / `不可关闭（系统或应用，默认折叠）`。
- 每行显示：端口（多端口显示 `+N`）、进程图标、归属标签、命令与 PID、运行时长、`LAN` 徽标（局域网可见时）。
- 悬停出现红色 `✕`，右键菜单：浏览器打开 / 复制端口 / 复制 PID / 关闭进程。
- 点击行进入详情：完整证据链（进程、用户、可执行路径、工作目录、项目标记、判定依据）。
- 关闭是**两步**：先看确认页（进程信息、其他端口警告、温和关闭说明），再点“关闭”。
- 托盘右键菜单：刷新 / 开机自启动（默认关）/ 退出。
- 再次启动 `LeftOpenApp.exe` 会唤起已运行实例的面板（可做快捷方式）。

## 命令行

```text
leftopen               # 列出所有监听活动
leftopen <port>        # 解释某个端口属于谁
leftopen open <port>   # 在浏览器中打开
leftopen close <port>  # 温和关闭端口上的进程
leftopen --json        # 机器可读输出
```

选项：`--pid <pid>`（一个端口被多个进程持有时指定）、`--dry-run`（只预览不发信号）、`--yes`（跳过交互确认）、`--no-color`。

```text
$ leftopen 5173
PORT 5173 · 1 listener
Owner:      fdi_project_info_web
Type:       project
Confidence: high
Process:    node.exe
PID:        5252
User:       MOMENTA\yan.gao1
Uptime:     2h 14m
Scope:      LOCAL
Addresses:  127.0.0.1
Executable: C:\nvm4w\nodejs\node.exe
CWD:        ~\workspace\fdi_project_info_web\
Marker:     ~\workspace\fdi_project_info_web\.git
Reason:     CWD is within a project root containing git at ...\.git.
```

## 工作原理：macOS → Windows 映射

| 原版（macOS） | 本移植版（Windows） |
|---|---|
| `lsof -iTCP -sTCP:LISTEN` | `GetExtendedTcpTable`（iphlpapi，netstat 同源的原生 API，自带 PID） |
| `ps -axo pid,ppid,comm` | 一次 WMI 查询拿到 PID/父 PID/可执行路径/命令行/启动时间 |
| `lsof -d cwd` 读工作目录 | 读目标进程 PEB 的 `RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`（`NtQueryInformationProcess` + `ReadProcessMemory`） |
| `.app` 包识别应用 | 可执行文件位于 `Program Files` / `WindowsApps` / `%LOCALAPPDATA%\Programs` |
| 系统目录 `/usr/bin` 等 | `C:\Windows` 树 |
| `127.0.0.1` vs `0.0.0.0` | 同样区分 `LOCAL`（仅本机）/ `LAN`（局域网可见） |
| 只发 SIGTERM | 温和关闭阶梯：WM_CLOSE → 控制台 Ctrl+C → Ctrl+Break |
| 菜单栏 `MenuBarExtra` | 系统托盘 `NotifyIcon` + 弹出面板 |

`LeftOpen.Core` 是共享引擎，托盘应用与 CLI 用的是**完全相同**的扫描、推断与关闭规则。

### 为什么关闭阶梯里要加 Ctrl+Break

Windows 没有 SIGTERM，最接近的“温柔”做法是模拟用户在那个终端里按键：

1. `WM_CLOSE` —— 有自己窗口的进程（GUI 程序）。
2. `AttachConsole` + `CTRL_C_EVENT` —— 等同于在该进程的终端里按 Ctrl+C，dev server（node/vite/next）会走正常的清理逻辑。
3. `CTRL_BREAK_EVENT` —— 由 PowerShell `Start-Process` 等方式启动的进程会被放进**新进程组**，新进程组默认忽略 Ctrl+C；Ctrl+Break 不受这个忽略模式影响，能可靠送达。

发送前，发送方会注册一个返回 `true` 的控制台事件处理器，确保这些事件不会把 LeftOpen 自己一起带走。

## 安全规则

关闭是**三段式**的，任何一步不满足就拒绝执行、绝不发信号：

1. **准备**：拒绝系统进程（PID ≤ 4）、LeftOpen 自身、非当前用户（含 SYSTEM）的进程、可执行文件位于 `C:\Windows` 的进程、以及“装在 Program Files 里的应用本体”（例如 Spotify）；共享运行时（node/python/dotnet…）不算应用本体，可以关闭。
2. **复核**（防 PID 复用）：发信号前重新扫描，核对目标 PID 仍在该端口监听、没有出现新的持有者、用户 SID / 可执行路径 / **启动时间**都与预览时一致——任何一项变化都判定为“PID 被换人”，放弃并明确报告“未发送任何信号”。
3. **执行**：发送温和信号后轮询最多 5 秒确认端口释放，结构化返回 `targetStoppedListening` / `portFree` / `remainingPids` / `signalsDelivered`。

**从不强杀**（没有 `taskkill /F`，没有 `Process.Kill`）。进程不响应就如实报告；连温和信号都送不到（既无可达窗口也无控制台）时，也会明确说明“未送达，进程未受影响”。

## 已知限制

- 管理员 / 受保护进程的工作目录读不到（PEB 不可读），这些进程归类为“未知”，面板会在底部列出限制说明。
- 32 位进程的 PEB 读取未做 WOW64 特化处理，失败时同样优雅降级。
- 使用 `http.sys` 的程序（如 .NET `HttpListener`）在 TCP 表中归属 PID 4（SYSTEM），因此会被识别为系统进程、不可关闭——这是 Windows 的行为，不是误判。
- `LAN` 只表示绑定地址不是回环地址，不代表防火墙后真的可达（与原版一致）。
- 面板暂不支持深色主题跟随与搜索历史。

## 项目结构

本目录是原仓库 [SonghaiFan/leftopen](https://github.com/SonghaiFan/leftopen) 的 `windows-port` 分支上的 Windows 移植部分；macOS 的 Swift 源码与 TypeScript CLI 原型仍在仓库根的 `Sources/`、`src/`，未做改动。

```
windows/
├── LeftOpen.sln
├── src/LeftOpen.Core/          # 引擎：TCP 表、进程事实、PEB 工作目录、项目识别、归属推断、关闭服务
├── src/LeftOpen.Tray/          # 托盘应用（WinForms）：门图标、面板、两步确认
├── src/LeftOpen.Cli/           # 命令行（leftopen.exe）
├── tests/LeftOpen.Core.Tests/  # 56 个单元测试（项目标记、排除规则、推断优先级、关闭规则）
└── Scripts/publish.ps1
```

## 测试

```powershell
dotnet test
```

覆盖：项目标记向上查找与排除规则（`node_modules`、缓存、AppData、系统树、home 根、隐藏目录）、归属推断优先级与置信度、局域网判定、父进程链（环检测与深度上限）、关闭保护规则、PID 复用复核、端口被抢占的报告、信号未送达的如实报告，以及端口字节序解析的回归测试。

## 致谢与许可

设计与交互来自 [SonghaiFan/leftopen](https://github.com/SonghaiFan/leftopen)（MIT）。本移植版沿用同一理念与安全模型。
