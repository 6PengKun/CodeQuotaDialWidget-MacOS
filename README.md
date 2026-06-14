# Code Quota Dial Widget

把 **Codex** 和 **GLM（智谱）** 的额度做成 macOS 桌面 Widget。

<img src="assets/example_all.png" alt="example" width="800" />

<img src="assets/example_desktop.png" alt="example" width="600" />

当前仓库的安装方式已经改成：

- 机器相关配置外置到 `local-config.env`
- 用 `script/install.command` / `script/rebuild-local.command` 统一构建、重签名、安装
- 不再要求手动去改 Swift、entitlements、`pbxproj`

## 适用范围

这套方案面向：

- 有 macOS
- 有 Xcode
- 愿意本机从源码构建

它不是“下载一个预编译 app 直接分发给所有人”的方案。  
每台机器仍然需要自己的 Apple 开发身份来生成本机可用的 App Group entitlement，但这一步已经由脚本自动处理。

## 项目结构

```text
CodeQuotaDialWidget/
├── Package.swift
├── script/
│   ├── install.command
│   ├── rebuild-local.command
│   └── uninstall.command
├── local-config.example.env
├── Sources/
├── Runtime/
└── XcodeApp/
```

## 工作原理

```text
LaunchAgent
  -> CodexQuotaSnapshotTool / GLMQuotaSnapshotTool
  -> 写入 App Group 共享容器里的 JSON 快照
  -> Widget 读取快照并刷新
```

宿主 App 负责注册 Widget Extension。  
两个 snapshot tool 负责定时抓额度，并调用 `WidgetCenter.shared.reloadAllTimelines()`。

## 前提条件

**需要这些环境：**

- **macOS 14+**
- **Xcode 16+（通过App Store下载）**
- **已登录 Xcode 的 Apple ID**

可选（缺少项则无法获取）：

- Codex widget 需要本机可用的 `codex` CLI，保持登录状态。
- GLM widget 需要 `~/.glm_quota_config.json`

GLM 配置文件示例：

```json
{"apiKey": "你的 GLM API Key"}
```

## 一键安装

克隆仓库后执行：

```bash
cd CodeQuotaDialWidget
./script/install.command
```

首次执行会自动：

1. 从本机开发身份探测 `Team ID`
2. 生成 `local-config.env`
3. 生成本机需要的 App Group 配置和 entitlements
4. 构建 App、Widget、两个 snapshot tool
5. 用 `ad-hoc` 方式重签名
6. 安装到 `/Applications/CodeQuotaDialXcode.app`
7. 生成并加载两个 `LaunchAgent`

之后再次更新只需要重新执行：

```bash
./script/install.command
```

或：

```bash
./script/rebuild-local.command
```

## 本地配置

第一次运行后会生成：

```bash
local-config.env
```

这里集中维护所有机器相关内容：

- `TEAM_ID`
- `CODEX_APP_GROUP`
- `GLM_APP_GROUP`
- `INSTALL_BASE`
- `REFRESH_INTERVAL`
- `CODEX_HOME`
- `PATH_PREFIX`
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `ALL_PROXY`
- `NO_PROXY`

你以后要迁移到另一台机器，原则上只需要重新运行 `script/install.command`，然后按需调整这一个文件。

## 安装结果

成功后会生成这些内容：

```text
/Applications/CodeQuotaDialXcode.app
~/Library/LaunchAgents/local.codex-quota-dial.refresh.plist
~/Library/LaunchAgents/local.glm-quota-dial.refresh.plist
Runtime/codex/CodexQuotaSnapshotTool
Runtime/glm/GLMQuotaSnapshotTool
```

共享容器中的快照路径：

```text
~/Library/Group Containers/<TeamID>.group.local.codex-token-monitor/codex_quota_snapshot.json
~/Library/Group Containers/<TeamID>.group.local.glm-quota-monitor/glm_quota_snapshot.json
```

## 验证安装

先看 LaunchAgent 是否已加载：

```bash
launchctl print "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl print "gui/$(id -u)/local.glm-quota-dial.refresh"
```

再看快照文件是否存在：

```bash
ls ~/Library/Group\ Containers/*codex-token-monitor/codex_quota_snapshot.json
ls ~/Library/Group\ Containers/*glm-quota-monitor/glm_quota_snapshot.json
```

手动触发一次刷新：

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.glm-quota-dial.refresh"
```

如果快照文件的修改时间前进，说明后台刷新链路正常。

## 这次排查的结论

这次“组件不更新”排查后，当前结论是：

- 重装后的 App Group entitlement 正常
- 两个 snapshot tool 可以正常写共享容器
- LaunchAgent 已成功加载
- 手动 `kickstart` 后两份快照的 `generatedAt` 会前进

也就是说，当前命令流安装出来的版本，刷新链路是通的。

## 常见问题

### 1. `script/install.command` 运行后没有生成 widget 数据

先看日志：

```bash
tail -n 100 Runtime/codex/logs/refresh.err.log
tail -n 100 Runtime/glm/logs/refresh.err.log
```

常见原因：

- `codex` CLI 不在 PATH 里
- `~/.glm_quota_config.json` 不存在
- 代理没配好
- `local-config.env` 里改坏了 App Group

### 2. App 能打开，但 widget 还是旧数据

先手动 kickstart：

```bash
launchctl kickstart -k "gui/$(id -u)/local.codex-quota-dial.refresh"
launchctl kickstart -k "gui/$(id -u)/local.glm-quota-dial.refresh"
```

然后检查快照时间是否前进。  
如果快照时间前进但桌面还没变，通常是 WidgetKit 自己的刷新延迟，等一小会或者移除再添加一次 widget。

### 3. 换机器后还能不能直接用

可以，但必须重新运行：

```bash
./script/install.command
```

因为新机器的 `Team ID`、App Group entitlement、LaunchAgent 路径都可能不同。

## 卸载

执行：

```bash
./script/uninstall.command
```

开发态全清可执行：

```bash
./script/uninstall.command --include-project-build
```

它会清理：

- `/Applications/CodeQuotaDialXcode.app`
- `~/Library/LaunchAgents/local.codex-quota-dial.refresh.plist`
- `~/Library/LaunchAgents/local.glm-quota-dial.refresh.plist`
- `~/Library/Group Containers/*codex-token-monitor`
- `~/Library/Group Containers/*glm-quota-monitor`
- `Runtime/codex/CodexQuotaSnapshotTool`
- `Runtime/glm/GLMQuotaSnapshotTool`
- `Runtime/*/logs`
- WidgetKit/Chrono 相关缓存
