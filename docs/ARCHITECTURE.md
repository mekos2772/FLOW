# 项目架构说明

对应规格「第二十四部分 · 交付物 #13」（**已于 2026-11-22 同步现状**）。本文描述的是**实际存在的目录与文件**，
文件数为 `find <dir> -name '*.swift' | wc -l` 的真实统计。

## 1. 分层与文件分布

| 目录 | Swift 文件 | 职责 |
|---|---:|---|
| `App/` | 4 | 应用入口、`AppDelegate`、`AppEnvironment`、Debug QA 钩子（`QAHarness`） |
| `DI/` | 3 | 依赖容器（`AppContainer` 含 `voice` / `voiceDriver`、`ContainerBuilder`）与 `SettingsStoring` 协议族 |
| `Core/` | 21 | 领域模型（`Track`、`TrackIdentity`、`SourceID`、`LyricsDocument`、沉浸场景与播放页背景枚举）、协议、错误、事件、`PlaybackClock`、`RedactingLog`、`KeychainSecretStore`、`RuntimeSandbox`、`AudioFeatureMeter`（分频电平与起音格子）、`UniversalFileClassifier` |
| `Playback/` | 8 | 状态机、协调器、`PlaybackCoordinator`（AI 优先、在线失败兜底本地缓存）/ `PlaybackEngine`、队列、Session 持久化、控制中心桥接 |
| `Sources/` | 35 | 多音源与音频管线：`Standard/`（本地音频库、OpenSubsonic/Navidrome、WebDAV）、`Plugins/`（`JavaScriptCore` 沙箱与 `JSPluginSandboxSupport`、MusicFree / LX 多配置与轻量元数据持久化、JSON 模板、`GitHubSourceDiscovery`、`ExternalAPIPresets`、`SourceDomainPolicy`、`PluginHTTPClient`、`ImportedSourceStore`）、`Audio/`（`MediaAudioCache`、`AudioStreamDescriptor`、`RemoteStreamSessionFactory` 与 `HLSResourceClient` 含受控 HLS、`HTTPStreamPlayerSession`、`OfflineLibraryManager`、5 段实时 EQ、`LoudnessAnalyzer`、`AudioProcessingTap` 与 `AudioBandSplitter`（分频与起音切格）、`ProgressiveAudioStream`、`AudioFade`）、`SourceManager`、`Mock/` |
| `Lyrics/` | 17 | `LRCParser`、`AMLLTTMLParser`、`AMLLLyricsIndex`/`Provider`、`LRCLIBSource`、`ExternalLyricsAggregator`、`LyricDocumentCache`、`LyricBindingStore`、`LyricVariantCoordinator`、`SourceAwareLyricsLoader`、`TextNormalizer`、`LyricEngine`、`LyricScrollLayout` |
| `Spatial/` | 12 | AX 窗口观察、安全区、空闲矩形、评分、多屏扫描、`SpatialCoordinator` |
| `Morphology/` | 14 | `MorphologyStateMachine`、`MorphologyEngine`、`WindowGeometryResolver`、`ContinuousPlacementSolver`、`AdaptivePlacementPlanner` 等纯逻辑层 |
| `Morph/` | 11 | `MorphWindowController`（形态、全屏、沉浸、普通 / 悬浮 / 沉浸三档）、`MorphPanel`、`MorphPresentationModel`、`PlayerMode`、`WindowFrameAnimator`、`UpNextPlanner` 等单窗口形态控制器 |
| `Overlay/` | 3 | `LyricsShape`（歌词排布）、`LyricsOpacity`、`FloatingLyricsControlling` |
| `UI/` | 42 | `Expanded/`（完整版面、歌名/歌曲行、歌词字段/搜词弹窗、传输带、抽屉、播放页背景、全域拖放路由）、`Immersive/`（沉浸页、Metal 渲染器与四个场景、节拍跟踪、调色板、背景画廊）、`Voice/`（音色导入工具、版本切换胶囊、在线音色获取、音色面板、参数面板）、`Bilibili/`（兼容保留的通用 `SongListState`/`PlaylistPageState` 状态模型）、`Compact/`、`Floating/`、`Settings/`（音源管理、自动获取与 GitHub 搜源、JS/JSON 导入、Server 配置、音色/底座模型/镜像/缓存） |
| `Voice/` | 25 | **纯原生 AI 翻唱**：`Vendor/OnnxRuntime/OnnxRuntime.xcframework` + `ORTSession`（CoreML/CPU EP & `RunOptionsSetTerminate` 取消）、`VoiceAudioDSP`（AVFoundation + `Accelerate/vDSP` STFT/ISTFT/Mel/Butterworth/RMS）、`MDXModelCatalog` / `MDXVocalSeparator`、`RMVPEPitchExtractor`、`F32VectorIndex`、`HuBERTFeatureExtractor`、`ONNXSineGenSanitizer`、`RVCVoiceConverter`、`VoiceModelAssetsManager`、`VoiceModelDiscovery`、`VoiceModelMirror`、`OnlineVoiceCatalog`、`CuratedVoiceCatalog`、`RVCEngineAdapter`、`VoiceCacheManager`（三级缓存）、`VoicePackStore`、`VoiceTaskManager`、`VoiceManager`、`VoicePlaybackDriver`、`VoiceContainer` |
| `DesignSystem/` | 6 | 设计令牌（`Tokens`）、基础组件（`FlowComponents`、`FlowIcons`）、封面取色（`ArtworkPalette`）、细轨道滑杆（`HairlineSlider`）、分段切换（`FlowSegmentedSwitch`） |
| `MenuBar/` | 1 | 状态项与下拉面板（`MenuBarView`） |
| `Integration/` | 24 | 热键、系统媒体、音频路由、睡眠定时、渐变驱动、`RelatedRadioDriver`、`PlaybackRecoveryDriver`、`StreamingResourceLoaderBridge`、`HLSResourceLoaderBridge`、深链、备份、隐私、小组件桥接 |
| `System/` | 2 | 壁纸亮度采样（`WallpaperLuminance`）与背景外观适配（`BackgroundAppearance`） |
| `Persistence/` | 24 | SwiftData Schema V1–V3 与迁移计划、仓库、设置存储、内存实现 |
| `Shared/` | 3 | 小组件快照与 App Group 共享存储 |
| `SpatialLyricsWidgets/` | 2 | Widget Extension 目标 |
| `Tests/` | 188 | 单元测试与测试替身支撑文件（规范文档见 `docs/SOURCE_SPEC.md`，外接插件与公开示例位于 `external-plugins/`，未打包进主应用） |
| `UITests/` | 1 | UI 测试（本机无开发证书签名，未执行） |
| `Scripts/` | — | `verify.sh`、`architecture-lint.sh`、`dead-code-scan.py`、`check-doc-numbers.sh` |

## 2. 单向依赖

```
App/DI  →  UI, Morph, MenuBar, Overlay, Integration, System
                ↓
        Playback, Lyrics, Spatial, Morphology, Voice
                ↓
        Sources, Persistence
                ↓
             Core
```

规则由 `Scripts/architecture-lint.sh` 与 `ArchitectureBoundaryTests` 共同强制：

- 表现层（`UI/`、`MenuBar/`、`Overlay/`、`Privacy/`）与 `Playback/` **不得**引用 `MockPlaybackSource`、`AVPlayer`、`AVAudioPlayer`、`URLSession`；`MenuBar/` 不得依赖完整/迷你播放器具体视图。
- `Shared/` 同时编入 App 与小组件 target，**不得**导入 `AppKit` / `SwiftUI` 或引用 `NSApplication` / `NSWindow`。
- 回调隔离：`Morph/`、`Spatial/`、`Integration/` 禁止 `MainActor.assumeIsolated`；`Playback/` 内 `MPMediaItemArtwork` 必须使用显式 `@Sendable` 闭包（见 `NowPlayingArtwork`）。
- 生产目录内**禁止**裸 `DispatchQueue.main.async`（改用 `Task` / `actor` / `RunLoop.main.perform(inModes:)`；仅 `architecture-lint.sh` 所注明显式豁免的 CoreAudio 桥接除外）。

## 3. 三处架构决策及其理由

### 3.1 播放状态：九态机 + 纯 reducer

`PlaybackStateMachine` 不做副作用，输入 `(state, event)` 返回
`(newState, [PlaybackEffect], accepted)`。副作用由 `PlaybackEngine` 执行。

- 理由：状态转换可纯函数测试（`PlaybackStateMachineTests` 13 条），无需真实音频。
- 反例被显式排除：规格禁止"用多个布尔量组合出状态"，`accepted` 标志让非法转换可观测而非静默吞掉。

### 3.2 播放进度：`PositionAnchor` 而非定时器

位置由 `(position, hostTime, rate)` 三元组按需推算。

- 理由：窗口/菜单栏/悬浮歌词读同一个锚点，不存在"三个定时器各自跑偏"。
- 暂停时 `rate = 0`，位置自然冻结，不需要额外分支。

### 3.3 空间布局：坐标压缩的最大空矩形 + 7 项评分

`FreeSpaceAnalyzer` 把障碍物边界投影到 x/y 轴做坐标压缩，在压缩网格上求最大空矩形；
`PlacementSolver` 对候选打分：

```
Score = FitReward + PreferredPositionReward + EdgePreferenceReward
      − OcclusionPenalty − MovementPenalty − MorphingPenalty − InstabilityPenalty
```

- 理由：规格禁止像素级栅格扫描。坐标压缩的复杂度只与**矩形数量**有关，与屏幕分辨率无关。
- 滞回参数：`DebounceWindow = 100ms`、`SnapDistance = 12pt`、
  `MinimumPlacementImprovement = 15%`、`MorphologyCooldown = 350ms`（早期是 800ms；数值以 `Spatial/PlacementSolver.swift` 与 `Morphology/MorphologyTuning.swift` 为准）。
- 关键规则：当前位置遮挡为 0 时，只有改善幅度超过 15% 才移动，否则 `.keepCurrent`。

## 4. 单一事实来源

| 事实 | 唯一来源 | 读取方 |
|---|---|---|
| 播放状态与进度 | `PlaybackCoordinator` / `PositionAnchor` | 主窗口、迷你、悬浮、菜单栏、小组件快照 |
| 歌词当前行 | `LyricEngine` | 同上 |
| 悬浮位置与形态 | `SpatialCoordinator` + `PlacementStoring` | 悬浮面板、设置页 |
| 用户设置 | `SettingsStoring` | 全应用 |

**曾经违反过这条**：`ContainerBuilder.app` 分支曾用 `InMemorySettingsStore()` 注入
`AppearanceSettings` / `PrivacyState`，导致迷你模式、置顶、字号、透明度全部读默认值。
已在 Round 22 修正，并有 `MiniModePersistenceTests` 等回归覆盖。

## 5. 持久化

- SwiftData，`VersionedSchema` V1 + V2 + V3，配 `SpatialLyricsMigrationPlan`。
- 辅助持久化与缓存（由 `RuntimeSandbox` 在生产/Debug QA 数据目录间自动隔离）：
  - `Application Support/FLOW/` 下含 `OfflineLibrary/`（显式离线曲目与音频文件）、`LyricBindings/`（按 `TrackIdentity` 绑定的 `.ttml` / `.lrc` 原文）与 `loudness-v1.json`（响度分析档案）；
  - `Caches/SpatialLyricsPlayer/` 下含 `amll-index.jsonl`、`amll-ttml/`、音频段与封面/歌词缓存。
- 损坏检测：读文件头判断是否为 SQLite；不是则隔离为 `*-corrupt-<ts>.store`，
  **不清空用户数据**。
- 测试替身：`InMemoryPlacementStore`、`InMemoryLyricsOffsetStore`（均为 `actor`，满足 `Sendable`）。

## 6. 并发约定

- 仓库与内存存储用 `actor`，避免加锁。
- UI 相关一切在主线程；`AppearanceSettings` / `PrivacyState` 标注 `@MainActor`。
- 后台计算（空间求解）不阻塞 UI；窗口写操作统一回主线程。
- `SWIFT_STRICT_CONCURRENCY = complete` + `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`。
- **Voice 的原生推理不阻塞主线程与 Swift 并发协作池**：`ORTSession` 在独立工作 `Thread` 中执行 ONNX Runtime 推理并持有 `OrtRunOptions` 支持 `RunOptionsSetTerminate` 实时取消，状态流转统一通过 `@MainActor` `VoiceTaskManager` 与 `VoiceManager` 管理。

## 7. 工程配置

- `objectVersion = 77`，使用 `PBXFileSystemSynchronizedRootGroup`：
  源文件按目录同步，**不需要逐个往 `project.pbxproj` 里加条目**。
- 四个 target：App、Widgets、Tests、UITests。

## 7.5 视觉层：DesignSystem 是所有界面的唯一取值来源

界面代码禁止写裸数字（圆角、间距、时长、字号），一律从 `DesignSystem/Tokens.swift` 取。
重构前审计到的现状是：全工程只有 2 处 `.animation(`、4 处散落材质、11 处硬编码圆角——
这正是"每个页面像不同人做的"的根因。

三条约束：

1. **动效按场景分曲线**，不是全员 `.easeInOut`：位移用 `Motion.move`（轻减速、落点确定、不弹跳），
   透明度用 `Motion.fade`（easeOut）。时长从 140ms（按钮）到 780ms（氛围色）分档。
2. **尊重"减少动态效果"**：所有动画经 `Motion.respectingReduceMotion` 过滤。
3. **颜色来自封面**：`ArtworkPalette` 取面积平均色后降饱和到 0.35、亮度夹到 0.62；
   取不到则回退系统强调色，不伪造颜色。

> 工程陷阱：`project.pbxproj` 用目录同步组（`PBXFileSystemSynchronizedRootGroup`），
> 新增顶层目录必须登记，否则文件**不参与编译**且 `xcodebuild build` 依然报成功。

## 8. 已知架构层面的欠账

- `UITests` 与正式 App Group 跨进程沙盒验证受限于本机缺少 Apple 开发者签名证书，目前主要依赖单元测试 + Debug 沙盒实机 GUI 交互验证（见 [HANDOVER.md](HANDOVER.md) 与 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)）。
- 部分依赖真实物理外设或系统级设置的链路（物理拔插耳机、多屏热插拔、合盖睡眠唤醒、全量 VoiceOver 试听）尚未在真实硬件上逐一人工走查。
- 完整缺口与签名/分发说明见 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) 与 [PERMISSIONS_AND_SANDBOX.md](PERMISSIONS_AND_SANDBOX.md)。

## 9. 形态系统（本轮新增）

### 9.1 为什么是"一个窗口"

规格 5.5 允许用两个窗口实现展开/收缩，但要求"同一实体"的连续感。
双窗口方案在任何一次交叠里都可能出现重影、闪白、屏幕坐标错位与抢焦点，
而这些恰好是规格 5.5 点名要排查的问题。单窗口从根上没有这些可能。

代价与对策：

| 代价 | 对策 |
|---|---|
| 完整形态没有系统标题栏 | 顶部栏自绘；拖动靠 `isMovableByWindowBackground`（公开 API） |
| 没有系统缩放手柄 | `UI/Expanded` 右下角自绘 `ResizeGrip`，控制器夹在 min 与安全区之间 |
| 关闭按钮语义不明 | 自绘 ✕ = 收进菜单栏（不是退出）；⌘W/⌘M 走同一条路径 |

### 9.2 四个纯逻辑部件

| 部件 | 输入 | 输出 | 测试 |
|---|---|---|---|
| `MorphologyStateMachine` | 事件 + 当前时刻 | 新状态 + 动作 + 原因/拒绝理由 | `MorphologyStateMachineTests`（17 条） |
| `MorphologyEngine` | 安全区、障碍物、当前形态 | 推荐形态 + 每个形态的适配度 | `MorphologyEngineTests`（11 条） |
| `WindowGeometryResolver` | 目标形态、当前矩形、安全区、障碍物 | 目标矩形 + 是否保住锚点 + 贴哪条边 | 同上（9 条几何断言） |
| `MorphTransitionPlan` | 起止形态与矩形 | 时长、是否需要淡出迁移 | 同上（3 条） |

窗口层 `MorphWindowController` 只做四件事：把系统事实变成输入、把输出变成 AppKit 动作、
维护持久化、处理焦点与层级。它不含任何形态判断逻辑。

### 9.3 自动收缩为什么不用"固定延时"

判断链（缺一不可）：

1. 本应用失去前台（`NSApplication.didResignActiveNotification` / `NSWorkspace` 通知）；
2. 失焦已稳定 ≥ `autoCollapseDelay`（700ms）；
3. 距最后一次用户主动操作 ≥ `interactionGrace`（1800ms）；
4. 距上一次形态切换 ≥ `morphologyCooldown`（800ms）；
5. 本次会话**真正播放过**，或用户有过交互（冷启动不许把界面收走）；
6. 用户没有锁定形态、没有显式隐藏、没有正在浏览抽屉（`isBrowsingAuxiliary`）；
7. 空间评估给出更紧凑的形态（`MorphologyEngine`）。

### 9.4 形态与歌词排布是两个维度

- **形态**（`PlayerMorphology`）决定尺寸、层级、焦点能力、能否缩放；
- **歌词排布**（`LyricsShape`）决定悬浮形态里显示几行：胶囊 56pt / 双行 76pt / 歌词板 152pt。

两者独立：切成贴边不该重置用户选的"双行"偏好（有测试 `testShapeAndMorphologyAreIndependent`）。

### 9.5 焦点与层级

| 形态 | level | canBecomeKey | collectionBehavior |
|---|---|---|---|
| expanded | `.normal` | true | `.managed`, `.participatesInCycle` |
| compact/capsule/edge | `.floating` | false | `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.ignoresCycle`, `.stationary` |
| dormant | 同上 | false | 同上（窗口通常已 `orderOut`） |

悬浮形态一旦能成为 key window，用户正在别的应用里打的字就会断；
因此 `MorphPanel.canBecomeKey` 跟随 `allowsKeyFocus`，而它只在完整形态为 true。

### 9.6 持久化的分工

| 数据 | 存储 | 理由 |
|---|---|---|
| 队列、曲目、历史、收藏、歌词偏移、播放进度 | SwiftData | 领域数据，需要版本迁移 |
| 每屏上次形态 / 贴哪条边 / 形态锁定 / 穿透 / 歌词排布 / 隐匿策略 | UserDefaults（`flow.morphology.v1`） | 纯展示偏好；避免为三个字段再改一次数据库 schema |
| 窗口原点与尺寸 / 显示器 ID | SwiftData `PlacementSnapshot` | 已有实现，跨分辨率按比例恢复 |

`PlacementSnapshot` 里的 `shape` 仍然只有 `LyricsShape` 的含义，形态另存——两者不要混用。
