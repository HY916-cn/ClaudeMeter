# ClaudeMeter

ClaudeMeter 是一款原生 macOS 菜单栏应用，通过本机安装的 **Claude Code CLI** 读取 Claude 订阅额度，显示剩余额度、重置时间和本地历史曲线。

本项目基于 [Raycal 的 CodexMeter](https://github.com/raycalrui/CodexMeter)（上游提交 `4c6baee`、版本 1.7.0）移植，沿用其 SwiftUI 菜单栏、图表、设置与历史存储设计。ClaudeMeter 初始版本为 **0.1.0**，是独立的社区移植项目，与 Anthropic 无隶属关系。

## 使用前准备

- macOS 13 或更新版本。
- 已安装支持 `--safe-mode`、`--ax-screen-reader` 的 Claude Code CLI（本次兼容性检查使用 2.1.217），终端中可执行 `claude`。
- 使用可查询订阅额度的 Claude 账户完成登录：

```bash
claude auth login
claude auth status --json
```

首次使用时，在应用使用的独立目录中完成 Claude Code 设置和目录信任，并确认 `/usage` 能显示用量：

```bash
mkdir -p "$HOME/Library/Application Support/ClaudeMeter/CLI"
cd "$HOME/Library/Application Support/ClaudeMeter/CLI"
claude /usage
```

然后打开 ClaudeMeter，通过菜单栏的刷新按钮读取额度。应用不会代替用户接受信任提示。API Key、第三方云平台认证或未订阅账户可能无法提供这一额度面板。

## 功能

- 菜单栏双环、百分比及多种紧凑显示方式；按剩余额度自动选择最紧张的窗口，或手动固定窗口。
- 当前会话与每周额度、CLI 返回的模型专属周额度、重置倒计时，以及有可靠重置时间时的消耗进度比较。
- 本地额度历史、当前周期及日历区间浏览、CSV 导出、保留期限设置和 `.claudemeterbackup` 备份恢复。
- 可配置菜单栏和弹窗、浅色/深色外观、英文、简体中文及繁体中文。
- 本地额度提醒、可选 Bark / Gotify / Telegram / Discord 补充额度通知，以及登录时启动。
- 开发者预览可检查不同额度状态和图表；预览数据与真实账户历史分开。

## 数据来源与限制

ClaudeMeter 执行 `claude auth status --json` 获取登录状态，通过伪终端运行交互式 Claude Code 的 `/usage` 读取额度。认证由 Claude CLI 管理；应用不读取 Claude 的认证文件，也不自行访问未公开的用量 HTTP 接口。该过程不提交模型提示词，并禁用工具与 hooks。

`/usage` 是终端界面，**不是稳定的结构化用量 API**。CLI 版本、输出格式、账户类型、首次设置或网络状况都可能影响读取。遇到未识别或不完整的输出时，应用显示错误，保留上次成功数据并标记为过期；不会把解析失败当作 0% 用量。账户切换会清除先前账户的可见额度。

当前 CLI 来源不提供每日 Token 明细、累计 Token 统计或可手动领取的额度重置机会。相应历史界面保留不可用状态，不以额度百分比推算 Token。缺少可可靠解析的重置时间时，剩余额度仍可显示，时间和进度估计保持不可用。

ClaudeMeter 使用手动安装更新。这个版本没有在线更新源；发布独立更新服务前，应配置自己的签名与发布地址。

自动刷新间隔为弹窗打开时 60 秒、后台 5 分钟；手动刷新立即执行，失败时保留过期标记。CLI 未返回可区分账户的身份时，只显示即时额度，暂停历史记录和额度通知。

## 本地数据与隐私

- 应用标识：`com.huang.ClaudeMeter`，偏好设置与原项目分开。
- 历史数据库：`~/Library/Application Support/ClaudeMeter/UsageHistory.sqlite`。
- 推送凭据保存在 `com.huang.ClaudeMeter.pushCredentials` 对应的本机钥匙串项目。
- 历史按本机加盐后的账户标识隔离，不保存账户邮箱、认证 Token 或原始 CLI 响应。
- 备份包括历史数据库与维持账户分区所需的本机盐值，不包含推送凭据或认证信息；恢复会替换现有历史，并要求重新打开应用。
- 远程通知默认关闭。启用后，只向用户配置的服务发送额度窗口名称与实际观测到的剩余额度。

## 开发与验证

源码目录和核心测试模块保留上游的 `CodexMeter` / `CodexMeterCore` 名称，以便追踪移植差异；应用产物为 `ClaudeMeter.app`。

本机也可使用 Swift 6.4、macOS 26.5 SDK 和 Python 3 直接构建，脚本会生成三语资源、应用图标并进行 ad-hoc 签名：

```bash
bash Scripts/build_local.sh
open dist/ClaudeMeter.app
```

macOS 27 SDK 的 SwiftUI 宏依赖完整 Xcode；脚本会优先使用已安装的 Command Line Tools 26.5 SDK，也可用 `SDKROOT` 指定 SDK。该本地构建没有 Apple 公证。

使用支持源码所需 Swift 与 SDK 的完整 Xcode 构建（上游要求 Xcode 27 beta 或更新版本）：

```bash
xcodebuild -project CodexMeter.xcodeproj -scheme ClaudeMeter \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

核心测试与推送服务的隔离测试：

```bash
swift test
bash Scripts/test_claude_cli.sh
bash Scripts/test_push_service.sh
git diff --check
```

推送测试使用模拟响应，不向真实通知服务发送消息。登录时启动、系统通知权限、文件面板和菜单栏交互仍需要在实际运行的签名应用中验证。真实订阅额度读取须以已登录账户完成一次 `/usage` 刷新为验收依据；解析器测试通过并不等于真实账户端到端验证通过。

`test_claude_cli.sh` 无需 XCTest，覆盖终端解析、时区、账户身份、进程超时/取消、输出上限与子进程清理。追加 `--live` 可检查当前 CLI，输出只包含登录状态和额度。`swift test` 的完整上游测试套件需要提供 XCTest 的 Xcode 环境。

## License

[MIT License](LICENSE). Original project copyright © 2026 Raycal. 原始许可证与作者归属保留；本仓库的 Claude CLI 适配与独立应用配置构成 ClaudeMeter 移植。
