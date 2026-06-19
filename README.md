# Code Quota Dial Widget

> 将 **Codex**、**Claude Code** 和 **GLM（智谱）** 的额度做成 macOS 桌面组件，随时一眼掌握用量。

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="platform" />
  <img src="https://img.shields.io/badge/Xcode-16%2B-147EFB" alt="Xcode" />
  <img src="https://img.shields.io/badge/Swift-Package-orange" alt="Swift" />
</p>

<p align="center">
  <img src="assets/example_all.png" alt="三个额度组件示例" width="800" />
</p>

<p align="center">
  <img src="assets/example_desktop.png" alt="桌面效果" width="600" />
</p>

---

## 目录

- [功能特性](#功能特性)
- [适用范围](#适用范围)
- [前提条件](#前提条件)
- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [项目结构](#项目结构)
- [本地配置](#本地配置)
- [安装结果](#安装结果)
- [验证安装](#验证安装)
- [常见问题](#常见问题)
- [卸载](#卸载)

---

## 功能特性

- 📊 在 macOS 桌面以表盘组件实时展示 Codex / Claude Code / GLM 三家额度。
- ⚙️ 机器相关配置全部外置到 `local-config.env`，无需手改 Swift、entitlements 或 `pbxproj`。
- 🔁 通过 `LaunchAgent` 定时抓取额度并自动刷新组件。
- 🚀 一条命令完成构建、重签名、安装：`script/install.command`。
- 🧩 三个组件相互独立，缺少某项凭据时只影响对应组件，不影响其它。

## 适用范围

这套方案面向：

- 拥有 macOS 设备
- 已安装 Xcode
- 愿意在本机从源码构建

它**不是**“下载一个预编译 app 直接分发给所有人”的方案。

每台机器仍然需要自己的 Apple 开发身份来生成本机可用的 App Group entitlement，但这一步已经由脚本自动处理。

## 前提条件

**必需环境：**

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 14+ |
| 构建工具 | Xcode 16+（通过 App Store 下载） |
| 开发身份 | 已登录 Xcode 的 Apple ID |

**可选凭据**（缺少对应项时，仅该组件无法获取数据）：

- **Codex 组件**：本机 Codex 已使用 ChatGPT OAuth 登录，可从 Keychain 读取 `Codex Auth`，或读取 `~/.codex/auth.json`。
- **Claude 组件**：本机 Claude Code 已登录，可从 Keychain 读取 `Claude Code-credentials`。
- **GLM 组件**：存在 `~/.glm_quota_config.json` 配置文件。

GLM 配置文件示例：

```json
{ "apiKey": "你的 GLM API Key" }
```

## 快速开始

克隆仓库后执行一键安装脚本：

```bash
cd CodeQuotaDialWidget
./script/install.command
```

首次执行会自动完成：

1. 从本机开发身份探测 `Team ID`
2. 生成 `local-config.env`
3. 生成本机需要的 App Group 配置和 entitlements
4. 构建 App、Widget 以及三个 snapshot tool
5. 使用 `ad-hoc` 方式重签名
6. 安装到 `/Applications/CodeQuotaDialXcode.app`
7. 生成并加载三个 `LaunchAgent`

安装完成后，**双击桌面 → 添加组件**即可。

后续更新只需重新执行以下任一命令：

```bash
./script/install.command
# 或
./script/rebuild-local.command
```

## 工作原理

```text
LaunchAgent
  -> CodexQuotaSnapshotTool / ClaudeQuotaSnapshotTool / GLMQuotaSnapshotTool
  -> 写入 App Group 共享容器中的 JSON 快照
  -> Widget 读取快照并刷新
```

- 宿主 App 负责注册 Widget Extension。
- 三个 snapshot tool 负责定时抓取额度，并调用 `WidgetCenter.shared.reloadAllTimelines()` 触发刷新。

## 项目结构

```text
CodeQuotaDialWidget/
├── Package.swift
├── local-config.example.env      # 本地配置模板
├── script/
│   ├── install.command           # 一键构建 + 安装
│   ├── rebuild-local.command     # 重新构建并重签名
│   └── uninstall.command         # 卸载
├── Sources/                      # Core / Widget / SnapshotTool 源码
├── Runtime/                      # 构建产物与运行日志
└── XcodeApp/                     # 宿主 App 工程
```

## 本地配置

首次运行后会生成 `local-config.env`，所有机器相关内容都集中在此维护：

| 变量 | 说明 |
| --- | --- |
| `TEAM_ID` | Apple 开发团队 ID |
| `CODEX_APP_GROUP` | Codex 组件 App Group |
| `CLAUDE_APP_GROUP` | Claude 组件 App Group |
| `GLM_APP_GROUP` | GLM 组件 App Group |
| `INSTALL_BASE` | 安装目录 |
| `REFRESH_INTERVAL` | 刷新间隔 |
| `PATH_PREFIX` | 可执行文件路径前缀 |
| `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` | 代理配置 |

> 迁移到另一台机器时，原则上只需重新运行 `script/install.command`，再按需调整这一个文件。

## 安装结果

安装成功后会生成以下内容：

```text
/Applications/CodeQuotaDialXcode.app
~/Library/LaunchAgents/local.codex-quota-dial.refresh.plist
~/Library/LaunchAgents/local.claude-quota-dial.refresh.plist
~/Library/LaunchAgents/local.glm-quota-dial.refresh.plist
Runtime/codex/CodexQuotaSnapshotTool
Runtime/claude/ClaudeQuotaSnapshotTool
Runtime/glm/GLMQuotaSnapshotTool
```

共享容器中的快照路径：

```text
~/Library/Group Containers/<TeamID>.group.local.codex-token-monitor/codex_quota_snapshot.json
~/Library/Group Containers/<TeamID>.group.local.claude-quota-monitor/claude_quota_snapshot.json
~/Library/Group Containers/<TeamID>.group.local.glm-quota-monitor/glm_quota_snapshot.json
```

## 验证安装

**1. 确认 LaunchAgent 已加载：**

```bash
launchctl print "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl print "gui/$(id -u)/local.claude-quota-dial.refresh"
launchctl print "gui/$(id -u)/local.glm-quota-dial.refresh"
```

**2. 确认快照文件已存在：**

```bash
ls ~/Library/Group\ Containers/*codex-token-monitor/codex_quota_snapshot.json
ls ~/Library/Group\ Containers/*claude-quota-monitor/claude_quota_snapshot.json
ls ~/Library/Group\ Containers/*glm-quota-monitor/glm_quota_snapshot.json
```

**3. 手动触发一次刷新：**

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.claude-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.glm-quota-dial.refresh"
```

> 若快照文件的修改时间随之前进，说明后台刷新链路正常。

## 常见问题

### 1. 运行 `script/install.command` 后没有生成 widget 数据

先查看日志：

```bash
tail -n 100 Runtime/codex/logs/refresh.err.log
tail -n 100 Runtime/claude/logs/refresh.err.log
tail -n 100 Runtime/glm/logs/refresh.err.log
```

常见原因：

- Codex 未使用 ChatGPT OAuth 登录，或 Keychain / `~/.codex/auth.json` 中没有可用凭据。
- Claude Code 未登录，或 Keychain 中没有 `Claude Code-credentials`。
- `~/.glm_quota_config.json` 不存在。
- 代理未配置正确。
- `local-config.env` 中的 App Group 被改坏。

补充说明：

- 截至 `2026-06-19`，Claude Code 本地保存的 OAuth 访问令牌默认约 `8` 小时过期一次。
- 本项目会在检测到 Claude OAuth 令牌过期或接口返回 `401` 时，尝试通过一次 `claude -p` 触发 Claude Code 刷新本地 OAuth 凭据，然后重试额度拉取。
- 这个刷新动作只用于更新本地登录态，不会产生任何 Claude 使用额度消耗，因此可以用于长期保持额度读取链路可用。

### 2. App 能打开，但 widget 仍是旧数据

先手动 kickstart：

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.claude-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.glm-quota-dial.refresh"
```

然后检查快照时间是否前进。若快照时间已前进但桌面仍未变化，通常是 WidgetKit 自身的刷新延迟，稍等片刻，或移除后重新添加 widget。

### 3. 换机器后还能直接用吗？

可以，但**必须重新运行**：

```bash
./script/install.command
```

因为新机器的 `Team ID`、App Group entitlement、LaunchAgent 路径都可能不同。

## 卸载

标准卸载：

```bash
./script/uninstall.command
```

开发态全清（含项目构建产物）：

```bash
./script/uninstall.command --include-project-build
```

卸载脚本会清理：

- `/Applications/CodeQuotaDialXcode.app`
- `~/Library/LaunchAgents/local.codex-quota-dial.refresh.plist`
- `~/Library/LaunchAgents/local.claude-quota-dial.refresh.plist`
- `~/Library/LaunchAgents/local.glm-quota-dial.refresh.plist`
- `~/Library/Group Containers/*codex-token-monitor`
- `~/Library/Group Containers/*claude-quota-monitor`
- `~/Library/Group Containers/*glm-quota-monitor`
- `Runtime/codex/CodexQuotaSnapshotTool`
- `Runtime/claude/ClaudeQuotaSnapshotTool`
- `Runtime/glm/GLMQuotaSnapshotTool`
- `Runtime/*/logs`
- WidgetKit / Chrono 相关缓存
