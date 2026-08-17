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

`DirectAnnotationController` → `RecordingToolbarController` → `ScreenRecorder` → `RecordingEditorController` → 保存或剪贴板

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
| `RecordingToolbarController.swift` | FPS、码率、音频、计时、开始/停止 | 估算、持久化、重复停止 |
| `ScreenRecorder.swift` | ScreenCaptureKit 录制与 MP4 写入 | 音视频同步、收尾和错误传播 |
| `RecordingEditorController.swift` | 视频预览、裁剪、标注、音频保留、导出 | 快速路径、进度、保存/剪贴板一致性 |
| `ShortcutRecorder.swift` / `GlobalHotKeyManager.swift` | 快捷键录制、注册和触发 | 冲突、持久化、生命周期 |
| `Localization.swift` / `AppBundle/Localizations` | 本地化读取和各语言字符串 | 新文本是否覆盖全部语言 |
| `AboutWindowController.swift` | 关于窗口及外部链接 | 版本信息和链接 |
| `CaptureDiagnostics.swift` | 截图与长截图诊断日志 | 日志中不得包含截图内容或敏感信息 |

## 4. 共享行为与耦合点

- `SharedAnnotationToolbar` 同时服务截图和录屏；新增工具或调整颜色交互时必须验证两条流程。
- `ScreenshotAnnotationMode` 是共享工具模式定义；修改枚举时同步检查直接标注和录屏标注适配层。
- `SelectionBorderController` 同时用于长截图与录屏区域；修改拖拽或锁定逻辑会影响两者。
- 坐标在 AppKit 全局点、显示器局部点和输出像素之间转换；转换应集中使用 `ScreenCapture` 辅助函数，避免各控制器自行取整。
- 录屏编辑器在“无裁剪、无标注、音频设置不变”时有原文件快速路径，改动导出逻辑时不得破坏该路径。

## 5. 本地持久化

当前通过 `UserDefaults.standard` 保存：

| 键 | 含义 |
| --- | --- |
| `shortcutKeyCode` | 全局快捷键键码 |
| `shortcutModifiers` | 全局快捷键修饰键 |
| `shortcutKeyLabel` | 快捷键显示文本 |
| `recording.capturesSystemAudio` | 是否录制系统声音 |

新增持久化设置时，应在此表记录键名、默认值和迁移策略，避免不同模块重复定义。

## 6. 平台与能力边界

- 应用最低支持 macOS 12；区域录屏仅在 macOS 13 及以上启用。
- 120 FPS 录制还取决于当前显示器刷新能力。
- 屏幕捕获必须获得系统“屏幕录制”权限。
- 应用当前采用临时/本地签名构建，发布说明须如实描述公证状态。
- 多显示器可能存在负坐标、不同缩放比例和不同可见区域，不能假定主屏原点为所有计算基准。

## 7. 测试与验证

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
