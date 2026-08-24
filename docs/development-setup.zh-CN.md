# Simprint 本地开发配置

本文按 Windows + PowerShell 编写，目标是从一台没有开发环境的机器开始，完成 Simprint 桌面端的依赖安装和开发启动。

## 1. 先了解项目结构

桌面端由以下部分组成：

| 目录                        | 作用                                        | 是否是桌面端启动的必需项 |
| --------------------------- | ------------------------------------------- | ------------------------ |
| 根目录、`src`、`plugins`    | React、Vite、TypeScript、Slotkit 界面与插件 | 是                       |
| `src-tauri`                 | Tauri 2、Rust 桌面外壳与本地服务            | 是                       |
| `src-tauri/crates/business` | SQLite 业务模型、迁移和服务                 | 是                       |
| `src-tauri/crates/runtime`  | 内嵌环境运行时和浏览器进程管理              | 是                       |

桌面端当前是 local-first 架构：前端通过 Tauri `invoke` 调用本地 Rust 服务，业务请求进入内嵌的 SQLite 业务层，环境运行时与主程序同进程运行。首次启动会自动创建本地用户、默认工作区、数据库和迁移表结构。

普通桌面端开发不需要 PostgreSQL、Redis、远程 API 或 `base_url`。

## 2. 安装 Windows 前置环境

### 2.1 Node.js

仓库的 CI 使用 Node.js 20。建议安装 Node.js 20 LTS，不建议使用与 CI 差异较大的版本作为开发基线。

安装后在 PowerShell 检查：

```powershell
node --version
npm --version
```

### 2.2 pnpm 9

仓库 CI 固定使用 pnpm 9，且 [`pnpm-lock.yaml`](../pnpm-lock.yaml) 的锁文件版本为 `9.0`。安装 pnpm 9：

```powershell
npm install --global pnpm@9
pnpm --version
```

### 2.3 Rust stable MSVC

安装 Rustup 后，确认使用 Windows MSVC 工具链：

```powershell
rustup default stable-x86_64-pc-windows-msvc
rustc --version
cargo --version
rustup show
```

如果 `rustup show` 中没有 `stable-x86_64-pc-windows-msvc`，补装目标：

```powershell
rustup target add x86_64-pc-windows-msvc
```

### 2.4 Visual Studio C++ 构建工具

通过 Visual Studio Installer 安装 Build Tools，并勾选：

- Desktop development with C++
- MSVC 编译工具
- Windows 10/11 SDK

缺少这些组件时，Rust 编译通常会出现 `link.exe`、Windows SDK 或 C++ 工具链错误。

### 2.5 WebView2

Tauri 2 使用 Microsoft Edge WebView2。Windows 11 通常已经安装；Windows 10 如果启动时提示缺少 WebView2，请安装 Microsoft WebView2 Runtime。

## 3. 获取代码并进入仓库

```powershell
git clone REPOSITORY_URL simprint
Set-Location D:\code\rust\simprint
```

后续命令默认都在 `D:\code\rust\simprint` 执行。路径可以替换为实际目录，但不要在仓库外执行根目录的 `pnpm install`。

## 4. 安装根目录前端依赖

使用锁文件安装，避免依赖解析结果漂移：

```powershell
pnpm install --frozen-lockfile
```

成功后应存在 `node_modules` 目录。若提示锁文件需要更新，优先确认 pnpm 是 9.x，不要直接删除锁文件或使用 `--no-frozen-lockfile`。

## 5. 安装 Tauri CLI

仓库的 [`src-tauri/Cargo.toml`](../src-tauri/Cargo.toml) 使用 Tauri 2，但根目录 `package.json` 没有声明 npm 版 Tauri CLI。项目 README 使用 Cargo 版命令，因此安装 Cargo CLI：

```powershell
cargo install tauri-cli --version "^2.0.0" --locked
cargo tauri --version
```

安装过程可能较慢，因为 Cargo 需要编译 CLI 本身。`cargo tauri --version` 能输出版本，才继续下一步。

## 6. 启动桌面端

```powershell
cargo tauri dev
```

启动过程会自动完成以下工作：

1. 执行 `pnpm dev`，启动 Vite/Slotkit 前端开发服务。
2. 编译 `src-tauri` 及两个本地 crate：`business`、`runtime`。
3. 创建本地 SQLite 数据库 `simprint.db`。
4. 执行内嵌数据库迁移，并初始化本地用户、工作区和浏览器内核目录。
5. 打开 Tauri 桌面窗口。

第一次编译 Rust 依赖可能需要较长时间，后续启动会使用 Cargo 缓存。

### 只调试前端

不需要 Rust 或 Tauri 窗口时，可以只启动前端：

```powershell
pnpm dev
```

但依赖 Tauri `invoke`、本地 SQLite、浏览器内核或系统窗口的功能，在纯 Vite 页面中不能完整工作。

## 7. 本地运行时与数据目录

Windows 正式运行时的默认根目录是：

```text
%LOCALAPPDATA%\Simprint
```

主要文件和目录如下：

| 路径                          | 用途                                         |
| ----------------------------- | -------------------------------------------- |
| `data\simprint.db`            | 用户、工作区、环境、代理、标签等本地业务数据 |
| `data\profiles`               | 正式运行时的浏览器 profile                   |
| `data\webview`                | Tauri WebView2 数据                          |
| `cache`                       | 浏览器缓存和内核下载缓存                     |
| `config\store.json`           | 应用设置                                     |
| `config\browser-kernels.json` | 可选的用户内核目录覆盖配置                   |
| `logs`                        | 应用日志                                     |

从源码仓库运行时，浏览器 profile 默认放在仓库的 `data\profiles`，便于开发环境和正式数据隔离；SQLite 数据库仍位于 `%LOCALAPPDATA%\Simprint\data\simprint.db`。应用设置可以覆盖 profile、缓存、日志和下载目录。

修改存储路径、备份数据库或移动 profile 前，应先关闭 Simprint 和所有由它启动的浏览器进程。不要在应用运行时直接替换 SQLite 数据库或浏览器 profile。

桌面端的核心业务不依赖远程服务，但以下功能仍可能访问网络：

- 下载浏览器内核和应用更新。
- 访问代理、目标网站以及 IP、语言或时区检测服务。
- 用户主动启用和调用的 Local API、MCP 或其他外部集成。

这些网络访问不等同于把本地工作区数据托管到 Simprint 社区服务器。

## 8. 启动成功后的检查

完成桌面端启动后，至少确认：

- 桌面窗口能够打开。
- 没有出现 `cargo tauri`、`link.exe` 或 WebView2 初始化错误。
- 应用数据目录中生成了 `simprint.db`。
- 能进入主界面，不会持续显示数据库初始化失败。

代码检查命令从仓库根目录执行：

```powershell
pnpm lint
pnpm format:check
pnpm rust:fmt:check
pnpm rust:check
```

## 9. 常见问题

### `cargo tauri` 不是有效命令

说明 Tauri CLI 没安装，执行：

```powershell
cargo install tauri-cli --version "^2.0.0" --locked
```

然后重新打开 PowerShell，再检查：

```powershell
cargo tauri --version
```

### `link.exe` 或 Windows SDK 找不到

重新打开 Visual Studio Installer，确认安装了 Desktop development with C++、MSVC 和 Windows SDK，并确认 Rust 使用 `stable-x86_64-pc-windows-msvc`。

### `pnpm install --frozen-lockfile` 失败

先检查版本：

```powershell
node --version
pnpm --version
```

优先使用 Node.js 20 和 pnpm 9。不要先删除 `pnpm-lock.yaml`。

### 桌面端需要远程服务地址吗？

不需要。当前桌面端的业务路由由 `src-tauri` 的本地 SQLite 业务层处理，开发启动不读取 `base_url`，也不要求本机存在 PostgreSQL 或 Redis。

### 浏览器内核下载或安装失败

先确认网络能够访问内核下载地址，并查看 `%LOCALAPPDATA%\Simprint\logs` 中的应用日志。Windows 杀毒软件或文件索引程序有时会短暂占用刚解压的内核文件；关闭相关浏览器环境后重试，通常不需要清理 SQLite 数据库。

## 10. 推荐的日常启动顺序

普通桌面端开发：

```powershell
Set-Location D:\code\rust\simprint
cargo tauri dev
```

前端页面开发：

```powershell
Set-Location D:\code\rust\simprint
pnpm dev
```
