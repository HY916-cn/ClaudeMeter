# ClaudeMeter

ClaudeMeter 是一款原生 macOS 菜单栏应用，通过本机安装的 **Claude Code CLI** 读取 Claude 订阅额度，显示剩余额度、重置时间和本地历史曲线。

本项目基于 [Raycal 的 CodexMeter](https://github.com/raycalrui/CodexMeter)（上游提交 `4c6baee`、版本 1.7.0）移植，沿用其 SwiftUI 菜单栏、图表、设置与历史存储设计。ClaudeMeter 当前版本为 **0.1.3**，是独立的社区移植项目，与 Anthropic 无隶属关系。

## 下载与安装

- [GitHub 仓库](https://github.com/HY916-cn/ClaudeMeter)
- [v0.1.3 发行版本](https://github.com/HY916-cn/ClaudeMeter/releases/tag/v0.1.3)
- [macOS Apple Silicon 安装包](https://github.com/HY916-cn/ClaudeMeter/releases/download/v0.1.3/ClaudeMeter-0.1.3-macOS-arm64.zip)

解压 ZIP，将 `ClaudeMeter.app` 拖入“应用程序”后打开。发行包使用 ad-hoc 签名，尚未经过 Apple 公证；首次打开可能需要在“系统设置 → 隐私与安全性”中确认打开。发行页提供 SHA-256 校验文件。

此安装包适用于 Apple Silicon Mac，系统要求为 macOS 13 或更新版本。请完成以下首次配置，再打开应用。

## 首次使用：按顺序完成配置

> [!IMPORTANT]
> **Claude CLI 登录和 ClaudeMeter 专用目录初始化是两个独立步骤，两步都必须完成。**
>
> **即使 `claude auth status` 已显示登录成功，也必须执行第 3 步，在 `~/Library/Application Support/ClaudeMeter/CLI` 中完成首次设置与目录信任，并亲眼确认 `/usage` 显示用量。** 在其他目录完成的信任不一定适用于这个目录。
>
> ClaudeMeter 会在后台启动 CLI，无法代替你回答交互式设置和信任提示。若跳过这一步，应用会提示需要完成设置，无法读取额度。

### 1. 确认 Claude Code CLI 已安装

打开 macOS 的“终端”，执行：

```bash
claude --version
```

应看到 Claude Code 的版本号。本版本已验证 CLI **2.1.217 / 2.1.302**，需要支持 `--safe-mode` 和 `--ax-screen-reader`。

若提示 `command not found`，可使用 [Claude Code 官方安装方式](https://code.claude.com/docs/en/setup#install-claude-code)：

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

安装结束后重新打开终端，再运行 `claude --version`。如果仍找不到命令，按安装器提示或[官方 PATH 排查说明](https://code.claude.com/docs/en/troubleshooting)修复后再继续。

### 2. 登录可查询订阅额度的账户

```bash
claude auth login
```

按终端提示完成浏览器登录，回到终端后检查：

```bash
claude auth status --json
```

应看到 `"loggedIn": true`。使用 Claude 订阅账户登录；API Key 或第三方云平台认证可能不提供订阅额度。**这一结果只确认登录成功，还需要继续第 3 步。**

### 3. 初始化 ClaudeMeter 专用目录，并打开用量面板

**将下面整段复制到终端执行。请保留双引号，因为路径中包含空格。**

```bash
mkdir -p "$HOME/Library/Application Support/ClaudeMeter/CLI" && \
cd "$HOME/Library/Application Support/ClaudeMeter/CLI" && \
claude /usage
```

按终端实际出现的提示完成操作：

1. 若出现主题、显示方式等首次设置，选择适合自己的选项并完成引导。
2. 若出现目录信任提示，确认显示的目录是 `~/Library/Application Support/ClaudeMeter/CLI`，再确认信任该目录。
3. 若仍要求登录，完成登录后继续。
4. 等待用量面板出现。若完成引导后停在普通输入框，输入 `/usage` 并按回车。

**成功标志：终端显示当前会话和每周的用量百分比（例如 `Current session`、`Current week`），而不是登录页或目录信任提示。**

看到用量面板后，可按 `Esc` 返回输入框，再输入 `/exit` 退出 CLI。以后 ClaudeMeter 会自行启动短暂的 CLI 进程，终端不需要一直开着。

### 4. 打开 ClaudeMeter，确认首次刷新

打开 `ClaudeMeter.app`，点击 macOS 菜单栏中的 ClaudeMeter 指示器，再点击刷新按钮，等待本次读取完成。应看到剩余额度百分比与更新时间；读取成功后会自动开始记录本地额度历史。

> [!WARNING]
> **已登录，但 ClaudeMeter 仍提示“完成首次设置和目录信任”？请重新执行第 3 步的整段命令。** 必须在上面的专用目录里运行，单独在其他目录执行 `claude` 或反复点击应用刷新，无法完成该目录的信任。
>
> **如果终端里的 `/usage` 本身不能显示用量，请先处理终端中的登录、账户订阅或网络提示，再返回 ClaudeMeter。** 应用以 CLI 返回的额度为准。

## 提示“数据可能已过期”时怎么办

> [!IMPORTANT]
> **“数据可能已过期”表示本次刷新没有获得新数据，并不等于登录失效或额度用完。**
> **如果你使用的是 0.1.2 或更早版本，请先升级到 0.1.3。** 此版本修复了 CLI 查询环境、启动工作目录以及终端局部重绘的兼容问题；旧版可能在终端 `/usage` 正常时仍持续显示缓存或超时。
>
> 如果提示 CLI 只返回缓存用量或查询频率受限，**保留应用运行，等提示中的时间自动重试即可；不要反复点击刷新或重复运行 `/usage`。** 手动刷新同样遵守冷却，避免继续增加查询请求。

Claude CLI 的 `/usage` 在查询失败时，可能显示 `Showing last-known usage`，即此前缓存的额度。[官方说明](https://code.claude.com/docs/en/costs#when-the-usage-request-fails)指出，常见原因是查询接口限流。ClaudeMeter 会保留上次成功读取的百分比及更新时间；应用重启后，确认当前账户身份即可从该账户的本地历史恢复显示，并标记为过期。恢复的数据不会触发额度通知或冒充新的历史记录；新数据到达后，过期提示会自动消失，历史记录也会继续更新。

如果经过多次自动重试仍未恢复，请在冷却结束后按上面的第 3 步检查终端 `/usage`：若终端也只显示缓存或限流，需等待 Claude 的查询服务恢复；若终端有完整的新数据而应用仍失败，请报告 Claude CLI 版本与应用中的错误提示。仅在明确提示未登录或目录未初始化时，重新执行相应配置步骤。

## 功能

- 菜单栏双环、百分比及多种紧凑显示方式；按剩余额度自动选择最紧张的窗口，或手动固定窗口。
- 当前会话与每周额度、CLI 返回的模型专属周额度、重置倒计时，以及有可靠重置时间时的消耗进度比较。
- 本地额度历史、当前周期及日历区间浏览、CSV 导出、保留期限设置和 `.claudemeterbackup` 备份恢复。
- 可配置菜单栏和弹窗、浅色/深色外观、英文、简体中文及繁体中文。
- 本地额度提醒、可选 Bark / Gotify / Telegram / Discord 补充额度通知，以及登录时启动。
- 开发者预览可检查不同额度状态和图表；预览数据与真实账户历史分开。

## 数据来源与限制

ClaudeMeter 执行 `claude auth status --json` 获取登录状态，通过伪终端运行交互式 Claude Code 的 `/usage` 读取额度。认证由 Claude CLI 管理；应用不读取 Claude 的认证文件，也不自行访问未公开的用量 HTTP 接口。该过程不提交模型提示词，并禁用工具与 hooks。应用分别关闭 CLI 的遥测、错误上报与自动更新；用量查询保持可用。读取时会处理 CLI 的终端行擦除与光标移动，避免将已清除的“刷新中”提示误判为仍未完成。

`/usage` 是终端界面，**不是稳定的结构化用量 API**。CLI 版本、输出格式、账户类型、首次设置或网络状况都可能影响读取。遇到未识别或不完整的输出时，应用显示错误，保留上次成功数据并标记为过期；不会把解析失败当作 0% 用量。账户切换会清除先前账户的可见额度。

当前 CLI 来源不提供每日 Token 明细、累计 Token 统计或可手动领取的额度重置机会。相应历史界面保留不可用状态，不以额度百分比推算 Token。缺少可可靠解析的重置时间时，剩余额度仍可显示，时间和进度估计保持不可用。

ClaudeMeter 使用手动安装更新。这个版本没有在线更新源；发布独立更新服务前，应配置自己的签名与发布地址。

正常自动刷新间隔为弹窗打开时 5 分钟、后台 10 分钟；手动刷新至少间隔 60 秒，并遵守失败后的冷却。CLI 返回缓存或明确限流时，按 5、10、20、30 分钟逐步延长重试间隔，成功后恢复正常频率。失败时保留上次成功数据、更新时间与过期标记。CLI 未返回可区分账户的身份时，只显示即时额度，暂停历史记录和额度通知。

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
bash Scripts/test_claude_recovery.sh
bash Scripts/test_claude_service.sh
bash Scripts/test_push_service.sh
git diff --check
```

推送测试使用模拟响应，不向真实通知服务发送消息。登录时启动、系统通知权限、文件面板和菜单栏交互仍需要在实际运行的签名应用中验证。真实订阅额度读取须以已登录账户完成一次 `/usage` 刷新为验收依据；解析器测试通过并不等于真实账户端到端验证通过。

`test_claude_cli.sh` 无需 XCTest，覆盖终端解析与局部重绘、时区、账户身份、子进程工作目录及环境、进程超时/取消、输出上限与子进程清理。追加 `--live` 可检查当前 CLI，输出只包含登录状态和额度。`swift test` 的完整上游测试套件需要提供 XCTest 的 Xcode 环境。

## License

[MIT License](LICENSE). Original project copyright © 2026 Raycal. 原始许可证与作者归属保留；本仓库的 Claude CLI 适配与独立应用配置构成 ClaudeMeter 移植。
