# Codex Quota Menu — macOS 菜单栏应用设计

- 日期：2026-07-14
- 状态：用户已批准
- 目标平台：macOS 14 及以上
- 分发范围：个人使用

## 1. 背景与目标

构建一个原生 macOS 菜单栏应用，用于随时查看当前 Codex 账户的额度窗口、额度重置时间、可用重置次数，以及每次重置额度的到期时间。

应用使用本机 Codex App Server 的稳定只读 JSON-RPC 方法 `account/rateLimits/read`，复用用户已存在的 Codex 登录态。应用不读取浏览器 Cookie，不要求用户再次输入 ChatGPT 凭据，也不保存账号令牌。

成功标准：

1. 菜单栏持续显示“最紧张额度的剩余百分比 · 可用重置次数”，例如 `47% · 5`。
2. 点击菜单栏后展示所有额度窗口、各自重置时间，以及全部可获取的重置额度到期时间。
3. 数据每 5 分钟自动刷新，并支持手动刷新。
4. 应用默认随用户登录启动，可在设置中关闭。
5. 每个即将到期的重置额度在到期前 24 小时发送一次 macOS 通知。
6. 应用是严格只读客户端；代码中不存在消耗重置额度的调用路径。

## 2. 非目标

- 不提供“立即重置额度”或任何消耗重置次数的按钮。
- 不展示或管理 OpenAI API Platform 的用量、余额或账单。
- 不抓取 ChatGPT 网页，也不依赖网页 DOM。
- 不读取、复制或持久化 Codex/ChatGPT 登录令牌。
- 不支持多账户切换。
- 第一版不面向其他用户分发，不包含 Apple Developer ID 公证或安装包。

## 3. 已确认的产品决策

### 3.1 应用形态

- 原生 SwiftUI 菜单栏应用。
- 使用 `MenuBarExtra` 展示状态，不在 Dock 中显示常驻图标。
- 菜单栏采用“信息型”布局：图标后直接显示剩余额度百分比和重置次数。
- 弹窗显示完整详情、刷新状态、最后成功更新时间和设置入口。

### 3.2 刷新与启动

- 应用启动后立即刷新一次。
- 每 5 分钟自动刷新。
- 用户可点击刷新按钮手动刷新。
- 多个同时发生的刷新请求合并为一次，不并发请求同一数据。
- 默认使用 `SMAppService.mainApp` 注册登录后启动；设置中允许关闭。

### 3.3 通知

- 默认启用到期提醒，但必须先获得 macOS 通知权限。
- 每个有到期时间的可用重置额度在到期前 24 小时提醒一次。
- 若应用首次取得数据时距离到期不足 24 小时但尚未到期，则立即发送一次临近到期提醒。
- 已过期、已兑换或无法识别状态的额度不安排通知。
- 通知权限被拒绝不会影响额度读取和展示。

## 4. 数据来源与已验证能力

应用启动本机 Codex CLI 的 App Server：

```text
/Applications/ChatGPT.app/Contents/Resources/codex app-server --stdio
```

初始化连接后仅发送：

```json
{"method":"account/rateLimits/read","id":1,"params":null}
```

当前本机 Codex CLI 0.144.2 生成的稳定协议 schema 已确认该响应包含：

- `rateLimits.primary` 与 `rateLimits.secondary`
- `usedPercent`
- `windowDurationMins`
- `resetsAt`
- `rateLimitResetCredits.availableCount`
- `rateLimitResetCredits.credits[]`
- 每条重置额度的 `status`、`grantedAt` 和 `expiresAt`

真实只读调用也已验证当前账户能够返回可用重置次数及每条额度的到期时间。该调用不会兑换或消耗重置额度。

## 5. 架构

### 5.1 `CodexQuotaMenuApp`

应用入口与生命周期管理：

- 创建 `MenuBarExtra`。
- 持有 `QuotaStore`。
- 启动和停止定时刷新任务。
- 在应用退出时停止 App Server 子进程。
- 设置 `LSUIElement = true`，保持纯菜单栏形态。

### 5.2 `QuotaStore`

`@MainActor` 可观察状态容器，负责把服务层数据转换为 UI 状态：

- `loading`：尚无数据，显示 `— · —`。
- `fresh(snapshot)`：最近成功刷新未超过 30 分钟。
- `stale(snapshot, error)`：保留缓存，但显示过期警告。
- `unavailable(error)`：无缓存且无法读取数据。

`QuotaStore` 负责：

- 应用启动、定时器和手动刷新入口。
- 合并并发刷新请求。
- 计算菜单栏的剩余百分比。
- 将成功快照写入缓存。
- 触发通知计划更新。

### 5.3 `CodexAppServerClient`

以 Swift `actor` 实现，封装 App Server 子进程和 JSON-RPC 通信：

- 使用 `Process` 直接启动固定可执行文件，不经过 shell。
- 使用 stdin/stdout 的换行分隔 JSON。
- 每个连接只执行一次 `initialize`，随后发送 `initialized` 通知。
- 为请求分配递增 ID，并把响应路由到对应 continuation。
- 对单次读取设置超时。
- 复用单个子进程，不为每次 5 分钟刷新重复启动进程。
- 子进程意外退出时自动重启一次；再次失败后交由下一次手动或定时刷新重试。

允许的方法采用代码级白名单：

```text
initialize
initialized
account/rateLimits/read
```

应用目标中不定义、不引用也不序列化 `account/rateLimitResetCredit/consume`。

### 5.4 `QuotaService`

服务层负责把协议响应映射为应用领域模型，隔离协议版本变化：

- 未知 JSON 字段由解码器忽略。
- 可选字段缺失时使用明确的“未知”状态，不伪造数值。
- 关键响应结构缺失时返回兼容性错误。
- 不把重置额度的后端 ID写入日志或 UI。

### 5.5 `QuotaCache`

最近一次成功快照以 JSON 保存到：

```text
~/Library/Application Support/Codex Quota Menu/quota-cache.json
```

缓存只包含展示所需的额度窗口、到期时间和获取时间，不包含登录凭据。缓存写入使用临时文件加原子替换，损坏时直接忽略。

### 5.6 `ExpiryNotificationScheduler`

使用 `UNUserNotificationCenter`：

- 根据 `expiresAt - 24 小时` 安排本地通知。
- 使用重置额度 ID 与到期时间生成本地去重键；原始 ID 不写入日志。
- 每次刷新后取消已经不存在或状态不再可用的待发送通知。
- 对 `expiresAt == null` 的额度显示“不过期”，不安排通知。

### 5.7 `LaunchAtLoginController`

封装 `SMAppService.mainApp`：

- 第一次成功启动后默认注册登录启动。
- 设置开关与系统注册状态保持同步。
- 注册失败时显示可操作错误，并引导用户在“系统设置 → 通用 → 登录项”中检查权限。

## 6. 数据模型与展示语义

### 6.1 额度窗口

内部模型：

```swift
struct QuotaWindow: Codable, Equatable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?
}
```

展示规则：

- 剩余百分比为 `clamp(100 - usedPercent, 0...100)`。
- 弹窗展示所有可用窗口，不假设永远只有 5 小时或每周两种。
- 已知持续时间使用友好标签，例如 300 分钟显示“5 小时额度”，10080 分钟显示“每周额度”。
- 未知持续时间显示“Codex 额度”。
- 菜单栏显示所有可用窗口中剩余百分比最低的一项，即最紧张的额度。
- 没有任何可用窗口时显示 `—`，不使用 100% 作为默认值。

### 6.2 重置额度

内部模型：

```swift
struct ResetCredit: Codable, Equatable, Identifiable {
    let id: String
    let status: Status
    let grantedAt: Date
    let expiresAt: Date?
    let title: String?
    let detail: String?
}
```

展示规则：

- 菜单栏使用后端返回的 `availableCount`，不以详情数组长度代替，因为后端可能限制详情条数。
- 详情仅展示 `available` 状态，并按 `expiresAt` 从早到晚排序，无到期日的项目排在最后。
- `credits == null` 时仍展示可用次数，并注明“到期详情暂不可用”。
- `expiresAt == null` 显示“不过期”。
- 最近 24 小时内到期的项目使用警示色。

## 7. 用户界面

### 7.1 菜单栏标题

正常状态：

```text
◉ 47% · 5
```

状态变体：

- 首次加载：`◉ — · —`
- 超过 30 分钟未更新：`◉ 47% · 5 !`
- 无缓存且不可用：`◉ 不可用`

### 7.2 弹窗

从上到下包含：

1. 标题、“最后更新”文字和刷新按钮。
2. 每个额度窗口的名称、剩余百分比、进度条和重置时间。
3. 可用重置次数总数。
4. 重置额度列表，每项显示标题和本地时区到期时间。
5. 错误或数据过期提示。
6. “登录时启动”和“到期通知”设置。
7. “打开 ChatGPT”“重新检测”和“退出”操作。

日期使用系统区域和当前时区格式化，不硬编码 CST 或中文日期格式。

## 8. 刷新流程

1. 应用启动并先加载缓存。
2. 定位 Codex CLI，优先使用 ChatGPT.app 内置路径；若不存在，再检查常见安装路径和 GUI 环境可用的 `PATH`。
3. 启动 App Server 并完成初始化握手。
4. 调用 `account/rateLimits/read`。
5. 解码为领域模型并更新 `QuotaStore`。
6. 原子写入缓存。
7. 更新即将到期通知。
8. 5 分钟后重复；手动刷新可提前触发，但与进行中的刷新合并。

## 9. 错误处理

- 短暂读取失败：继续展示最近成功快照，并在弹窗显示具体错误和最后成功更新时间。
- 距最后成功刷新超过 30 分钟：进入 `stale`，菜单栏增加 `!`。
- 找不到 Codex CLI：显示安装/打开 ChatGPT 的说明和“重新检测”按钮。
- Codex 未登录：提示用户在 ChatGPT/Codex 完成登录；插件不提供凭据输入框。
- App Server 超时：取消当前请求，保持缓存，并在下一周期重试。
- 子进程退出：自动重启一次，避免无限重启循环。
- JSON 行损坏：记录不含个人数据的诊断信息并返回协议错误。
- 协议关键字段变化：显示“当前 Codex 版本暂不兼容”，应用不崩溃。
- 通知权限被拒绝：设置中显示未启用状态，额度功能继续工作。
- 登录启动注册失败：保持应用运行并提供系统设置路径。

## 10. 隐私与安全

- App Sandbox 关闭，因为应用需要启动 ChatGPT.app 内置的 Codex 子进程，并由该进程访问现有 `~/.codex` 状态。
- 应用本身不直接读取 `~/.codex` 数据库或认证文件。
- 不访问浏览器数据、Cookie 或钥匙串中的 ChatGPT 凭据。
- 不使用 shell 拼接命令；`Process.executableURL` 和参数均为固定、验证后的值。
- 不记录完整 App Server 响应、账号标识、重置额度 ID 或认证信息。
- JSON-RPC 方法使用只读白名单，单元测试检查不存在 `consume` 方法。
- 所有缓存仅存放额度展示数据；卸载说明包含缓存清理路径。

## 11. 测试策略

### 11.1 领域模型与解码

- 主额度窗口、次额度窗口和多额度桶。
- 剩余百分比计算及 0...100 边界。
- `credits == null`、空详情、详情数少于 `availableCount`。
- `expiresAt == null`、未知状态和未知 JSON 字段。
- 到期时间排序与系统时区格式化。

### 11.2 App Server 客户端

通过可替换传输层和假 App Server 测试：

- 初始化握手和读取成功。
- 请求超时、异常 JSON、无关通知和乱序响应。
- 子进程退出后仅重启一次。
- 并发刷新合并。
- 发出的方法集合不包含 `account/rateLimitResetCredit/consume`。

### 11.3 状态与缓存

- 启动时先显示缓存，再显示新数据。
- 5 分钟定时刷新。
- 30 分钟后从 `fresh` 进入 `stale`。
- 缓存原子写入、损坏缓存忽略和无缓存错误状态。

### 11.4 通知

- 到期前 24 小时安排一次。
- 首次发现时已进入 24 小时窗口则立即提醒一次。
- 同一额度不重复提醒。
- 过期、已兑换、未知状态和无到期日不提醒。
- 权限拒绝不会使刷新失败。

### 11.5 UI 与真实验收

- 测试正常、加载、过期和不可用的菜单栏标题。
- 测试弹窗中多个额度窗口和重置额度排序。
- 从 `/Applications` 启动构建后的 `.app`，与真实 App Server 只读响应对照。
- 验证手动刷新、5 分钟刷新、通知权限两种状态和登录启动。
- 验证应用退出时 App Server 子进程被清理。

## 12. 构建与交付

- 使用 Xcode 原生 macOS App 工程、SwiftUI、Swift Concurrency 和 XCTest。
- Bundle ID 使用 `local.scott.CodexQuotaMenu`。
- 个人构建采用本地或 ad-hoc 签名，不进行公证。
- 成品复制到 `/Applications/Codex Quota Menu.app` 后完成首次启动和通知授权。
- 交付内容：源代码、自动化测试、可安装 `.app`、README、安装与卸载说明。

## 13. 验收清单

- [ ] 菜单栏显示最紧张额度的剩余百分比和后端可用重置次数。
- [ ] 弹窗显示所有额度窗口和可获取的每次到期时间。
- [ ] 真实数据与 `account/rateLimits/read` 返回值一致。
- [ ] 5 分钟自动刷新与手动刷新工作正常。
- [ ] 30 分钟未更新时显示过期警告。
- [ ] 到期前 24 小时通知只发送一次。
- [ ] 登录后自动启动可启用和关闭。
- [ ] 未登录、无网络、找不到 Codex 和协议错误均不会导致应用崩溃。
- [ ] 源码和测试中不存在消耗重置额度的方法。
- [ ] 从 `/Applications` 启动的最终 `.app` 通过真实运行验收。
