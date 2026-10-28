# SuperScreenshot 开发架构与修改指南

本文档帮助开发者快速定位功能、判断改动影响范围。产品行为以 [REQUIREMENTS.md](REQUIREMENTS.md) 为准。

## 1. 技术概览

- 原生 Swift/AppKit 菜单栏应用，使用 Swift Package Manager 构建。
- 最低系统版本为 macOS 12.0。
- 截图和录屏基于 ScreenCaptureKit/CoreGraphics；视频编辑与导出使用 AVFoundation。
- 更新使用 Sparkle 2。
- 发布产物为同时包含 arm64 与 x86_64 的 Universal 应用和 ZIP。

## 2. 核心流程

### 截图

`AppDelegate/全局快捷键` → `CaptureCoordinator.beginSelection()` → `SelectionOverlayController` → `DirectAnnotationController` → 剪贴板、长截图或录屏

### 长截图

`CaptureCoordinator.startLongCapture()` → `LongCaptureEngine` → `ImageStitcher` → 长截图状态与预览 → `ScreenshotEditorController`

### 录屏

`DirectAnnotationController`（齿轮预设/一键开始） → `RecordingToolbarController` → `ScreenRecorder` → `RecordingEditorController` → 保存或剪贴板

## 3. 模块与职责

| 文件 | 主要职责 | 修改时重点检查 |
| --- | --- | --- |
| `SuperScreenshotApp.swift` | 应用生命周期、菜单栏、录屏状态图标、更新入口 | 菜单本地化、录屏状态切换 |
| `CaptureCoordinator.swift` | 截图/长截图/录屏流程编排和控制器生命周期 | 覆盖层清理、异步状态、显示器归属 |
| `SelectionOverlay.swift` | 多屏覆盖层、窗口识别、拖选、取色提示 | 坐标系、非激活窗口、键鼠事件 |
| `ScreenCapture.swift` | 权限、显示器快照、坐标与像素裁剪 | Retina、偏移显示器、系统版本 |
| `DirectAnnotationController.swift` | 选区上的直接标注、选区调整、工具栏转场 | 截图/长截图/录屏入口一致性 |
| `SharedAnnotationToolbar.swift` | 截图与录屏共享的标注工具栏 | 两类编辑器回调是否同步 |
| `ScreenshotEditor.swift` | 独立图片编辑器和标注画布实现 | 命中测试、文字编辑、渲染结果 |
| `LongCaptureEngine.swift` | 长截图采集、自动滚动和任务状态 | 捕获节奏、停止/取消、预览提交 |
| `ImageStitcher.swift` | 位移检测、重叠匹配和图像拼接 | 重复内容、最小重叠、末尾判断 |
| `LongCaptureStatus.swift` | 长截图状态、预览与控制 | 所在显示器、用户反馈 |
| `SelectionBorder.swift` | 长截图/录屏选区边框及调整 | 选区边界、锁定状态 |
| `RecordingToolbarController.swift` | 齿轮设置面板、保存参数、直接开始、计时与停止 | 估算、持久化、重复停止 |
| `RecordingPreferences.swift` | 参数持久化及当前屏幕/选区的有效参数限制 | 高帧率回退、码率上限、默认值 |
| `ScreenRecorder.swift` | ScreenCaptureKit 录制与 MP4 写入 | 音视频同步、收尾和错误传播 |
| `RecordingEditorController.swift` | 视频预览、裁剪、标注、音频保留、导出 | 快速路径、进度、保存/剪贴板一致性 |
| `ShortcutRecorder.swift` / `GlobalHotKeyManager.swift` | 快捷键录制、注册和触发 | 冲突、持久化、生命周期 |
| `Localization.swift` / `AppBundle/Localizations` | 本地化读取和各语言字符串 | 新文本是否覆盖全部语言 |
| `AboutWindowController.swift` | 关于窗口及外部链接 | 版本信息和链接 |
| `CaptureDiagnostics.swift` | 截图与长截图诊断日志 | 日志中不得包含截图内容或敏感信息 |

## 4. 共享行为与耦合点

- `SharedAnnotationToolbar` 的主行仅保留录屏、最近工具、长截图、完成，记录/长截图采用同高 48 pt 的灰色按钮；录屏右上角叠加独立齿轮点击区。撤销与删除放在左侧独立的 `actionsBackground/actionStrip` 中，仅有标注时出现。
- `SharedAnnotationToolbar` 同时服务截图和录屏；新增工具或调整颜色交互时必须验证两条流程。
- `ScreenshotAnnotationMode` 是共享工具模式定义；修改枚举时同步检查直接标注和录屏标注适配层。
- `SelectionBorderController` 同时用于长截图与录屏区域；修改拖拽或锁定逻辑会影响两者。
- 坐标在 AppKit 全局点、显示器局部点和输出像素之间转换；转换应集中使用 `ScreenCapture` 辅助函数，避免各控制器自行取整。
- 录屏编辑器在“无裁剪、无标注、音频设置不变”时有原文件快速路径，改动导出逻辑时不得破坏该路径。

- 自由画笔在 `ScreenshotEditorView` 中记录输出像素坐标、颜色和笔宽；输入按视图缩放换算笔宽，预览与导出共用渲染分支。画笔模式优先新增笔画，其他形状工具可命中笔画并整体移动；自由笔画不提供缩放手柄。
- `SharedAnnotationToolbar` 提供画笔与粗细控件；独立长截图编辑器同步提供入口。笔宽默认 4 pt，范围 1–24 pt，仅保存在当前编辑会话。

- `AnnotationToolsHoverView` 负责工具与参数区域的悬停。移入显示参数气泡并启动可取消的 1 秒任务，提前退出取消，右击当前工具可立即展开。离开两个区域后延迟 180 ms 收起，选择后阻止鼠标未离开时重开。
- 参数使用 `NSPopover`，不改变主条高度；工具选择通过 `animateLayout` 用 220 ms smoothstep 插值宽度、图标偏移与透明度。记录当前工具的屏幕锚点，每帧修正窗口位置或内嵌布局中心；屏幕边缘限制窗口位置。减少动态效果时立即切换。
- 主条高度 48 pt、初始宽 348 pt，有标注时向左增加 94 pt（86 × 48 pt 操作胶囊 + 8 pt 间距），高度保持 48 pt，工具展开增加 190 pt；录屏与长截图与底板融合，完成按钮为深绿色，工具选中使用浅蓝背景，无外发光。
- `closeTransientUI()` 在完成、录屏、长截图、关闭或隐藏编辑器时取消悬停任务并关闭参数气泡，避免临时 UI 泄漏进下一状态。
- `RecordingToolbarController` 在录制中按时间与视频/音频码率计算累计 MB 估算；与设置中的每分钟大小估算分开显示，不代表文件实测大小。

- 录屏设置采用 360 × 136 pt 三行布局，无完成按钮；设置更改自动保存。录屏齿轮通过 `AnnotationSettingsHoverButton` 的进入/退出回调显示设置；`RecordingToolbarController` 管理 180 ms 可取消关闭任务，气泡进入取消、退出重新计时。录制中使用 468 × 72 pt 布局：计时、双行参数/估算、结束、隐藏五个控件互不覆盖，准备状态的 FPS 标签须隐藏。

- `InstantTooltipToolbarView` 使用独立的忽略鼠标 `NSPanel` 展示提示，取消工具条内裁切；`ToolbarTooltipPlacement` 统一计算屏幕坐标、可见边界和光标避让区域。工具折叠或关闭时通过 `dismissInstantTooltip()` 清理。`Tests/ToolbarTooltipPlacementTests.swift` 覆盖顶部翻转、光标避让及偏移显示器边缘。

## 5. 本地持久化

当前通过 `UserDefaults.standard` 保存：

| 键 | 含义 |
| --- | --- |
| `shortcutKeyCode` | 全局快捷键键码 |
| `shortcutModifiers` | 全局快捷键修饰键 |
| `shortcutKeyLabel` | 快捷键显示文本 |
| `recording.frameRate` | 预设帧率，默认 60 FPS；不支持 120 FPS 的屏幕实际回退到 60，不覆盖预设 |
| `recording.bitRateMbps` | 预设码率，默认 1 Mbps，录制时按选区和有效帧率限制到 1–60 Mbps |
| `recording.capturesSystemAudio` | 是否录制系统声音 |

新增持久化设置时，应在此表记录键名、默认值和迁移策略，避免不同模块重复定义。

- `DirectAnnotationController` 持有录屏设置控制器；`RecordingToolbarController` 以 transient `NSPopover` 锚定右上角齿轮，关闭时保留选区及画布，选区变化时更新码率范围；开始录制时关闭设置，转入已锁定边框和紧凑录制工具条。
- `RecordingToolbarController.show(settingsOnly:settingsAnchor:)` 复用 FPS、码率和音频控件；`startImmediately` 无需显示准备界面便触发录制，开始成功后才启动计时和启用停止。启动失败时由协调器清理录制状态并恢复截图选区。

## 6. 平台与能力边界

- 应用最低支持 macOS 12；区域录屏仅在 macOS 13 及以上启用。
- 120 FPS 录制还取决于当前显示器刷新能力。
- 屏幕捕获必须获得系统“屏幕录制”权限。
- 应用当前采用临时/本地签名构建，发布说明须如实描述公证状态。
- 多显示器可能存在负坐标、不同缩放比例和不同可见区域，不能假定主屏原点为所有计算基准。

## 7. 测试与验证

- `Tests/RecordingPreferencesTests.swift` 验证录屏设置持久化、无效值恢复、120 FPS 回退和码率限制，以及左侧按钮/文字模式布局、设置不触发录制和一键启动回调。AppKit 窗口交互测试单独串行执行；核心测试可使用 `swift test --disable-sandbox --skip RecordingToolbarInteractionTests` 完整运行。
- `Tests/FreehandBrushTests.swift` 验证轨迹转折和松手终点、相交笔画独立撤销、移动删除、点状笔画、视图缩放与选区偏移后的导出像素。
- `Tests/ImageStitcherTests.swift` 当前覆盖显示器坐标、Retina 像素对齐和长截图拼接关键场景。
- 修改 `ScreenCapture`、`ImageStitcher` 或 `LongCaptureEngine` 时，先添加问题复现测试，再运行 `swift test`。
- 标注、AppKit 窗口交互和录屏导出目前主要依靠手工验证；涉及这些模块时至少走通截图完成、长截图、无声录屏、有声录屏、裁剪与导出路径。
- 每轮修改完成后运行 `./build-app.sh`，确认：
  - `outputs/SuperScreenshot.app` 存在；
  - `outputs/SuperScreenshot-v<版本>-Universal.zip` 存在；
  - 应用内版本与 ZIP 文件名一致；
  - 主可执行文件包含 arm64 和 x86_64。

## 8. 修改检查清单

1. 先在 `REQUIREMENTS.md` 更新产品行为或验收标准。
2. 根据模块表确认直接影响和共享影响。
3. 新增用户可见文字时同步更新全部 `.lproj/Localizable.strings`。
4. 新增设置时记录默认值、`UserDefaults` 键和兼容策略。
5. 补充或运行与风险相称的自动测试与手工流程。
6. 在 `CHANGELOG.md` 的“未发布”章节记录用户可感知变化。
7. 构建 Universal 应用与 ZIP，并核对版本和架构。
8. 发布到 `appcast.xml` 时添加更新说明、签名并核对最终 feed。

## 9. 后续可维护性改进

- 优先将超大控制器中的“标注模型/命中测试/渲染”和“窗口布局/流程编排”逐步拆开，但不要为拆分而改变现有用户行为。
- 为快捷键持久化、文字标注状态转换、录屏大小估算和导出决策增加纯逻辑测试。
- 保持需求编号或章节稳定，使问题、提交和测试可以引用同一行为定义。
