# Codex Quota Menu：额度数字与应用图标设计

## 目标

1. 将额度窗口中每个额度窗口右侧的剩余百分比数字固定显示为白色，避免在深色菜单栏窗口中因系统强调色或继承样式变成黑色。
2. 为应用包配置一个可被 Finder、启动台和 Dock 识别的 macOS 图标。
3. 保留现有菜单栏中的实时额度百分比和颜色药丸，不用静态应用图标替换实时状态显示。

## 视觉方案

应用图标采用“额度药丸 + 闪电”概念：

- 深色、方形、圆角背景，适配 macOS 图标环境。
- 蓝色主额度药丸，内部保留一段可读的剩余量视觉。
- 白色闪电作为“Codex 使用/额度”识别符号。
- 不放置动态百分比、账户信息或文本，避免图标在小尺寸下不可读。
- 图标不预先绘制 macOS 圆角遮罩，由系统负责最终图标外形。

## 代码与资源边界

### 额度数字

在 `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift` 的额度窗口行中，为
`Text("\\(window.remainingPercent)%")` 显式设置白色前景色。只改变该数字的呈现，
不改变额度模型、计算、阈值或其他文字层级。

### 应用图标

- 在 `Resources/` 增加图标源文件及可复现的生成脚本/资源。
- 由 `scripts/build-app.sh` 在构建 `.app` 时把生成的图标复制到
  `Contents/Resources/`。
- 在 `Resources/Info.plist` 增加 `CFBundleIconFile`，值指向应用包内的图标文件。
- 不引入第三方运行时依赖；图标生成只使用 macOS 自带工具或仓库内的静态资源。
- `MenuBarQuotaLabel.swift` 保持现有额度药丸逻辑，包括 20%/10% 的颜色阈值和
  无模板渲染设置。

## 构建与验证

新增或更新打包契约检查，至少验证：

- 额度视图源码显式包含白色前景色配置。
- `Info.plist` 声明图标文件。
- `scripts/build-app.sh` 把图标放入 `.app/Contents/Resources`。
- 构建后的图标文件存在且 `plutil` 可以读取应用包 Info.plist。
- 现有 `scripts/test.sh`、`scripts/verify-app.sh` 和
  `scripts/audit-outbound-methods.sh` 继续通过。

## 验收标准

- 打开额度窗口后，周额度和五小时额度的百分比数字均为白色。
- Finder/启动台显示“额度药丸 + 闪电”应用图标。
- 菜单栏仍显示实时百分比与颜色药丸，颜色规则不变。
- 应用仍然只读取额度数据，不新增任何写入或重置额度调用。
- 所有自动化测试和应用包验证命令退出码为 0。
