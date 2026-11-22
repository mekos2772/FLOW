# 交接文档 — FLOW（工程名 Spatial Lyrics Player）

> 面向接手者的单人可读版：这个工程现在处于什么状态、怎么跑起来、哪里是坑、哪些结论有实测支撑、下一步该做什么。
> **口径**：只有"已实测 / 已截图"的才标完成；未做的明确写未做。

最后更新：**2026-11-22**（FLOW Voice ContentVec/SineGen 杂音根治、`AppContainer.voiceDriver` 强持有、JS 插件历史元数据持久化、切回原曲本地缓存兜底与底栏切换胶囊防截断修复；自动避让与冷启动检测稳定性修复；设置页「自动获取与扩展预设」整合与 GitHub 自动搜源/jsDelivr 回退；FLOW Voice 底座与音色在线自动获取及默认镜像源；全应用降门槛改造；沉浸播放模式与全量代码审计收口，见 [CODE_AUDIT_2026-11-21.md](CODE_AUDIT_2026-11-21.md)）。

**阅读顺序**：本文 → [README](../README.md)（功能与文档地图）→ 按需读 [沉浸播放模式](IMMERSIVE_MODE.md)、[多音源标准](SOURCE_SPEC.md)、[已知限制](KNOWN_LIMITATIONS.md)、[下一步](NEXT_STEPS.md)。
2026-11-14 到 11-20 的逐次改动记录（第 7.5–7.10 节、第 9–215 节）原样移到了 [交接日志](archive/HANDOVER_LOG.md)，其他文档里的"第 N 节"都指那里。

测试条数、覆盖率等基线数字只写在 [上线清单](RELEASE_CHECKLIST.md) 与 [`evidence/coverage.txt`](evidence/coverage.txt)，其余文档一律链接过去，不再抄数字。

仓库根目录在本工程的**上一级** `music/`（历史原因；公开仓库以本工程目录为根）。只有本地 `main` 分支，没有配置远程。

---

## 1. 一分钟了解

macOS 14+ 原生**多音源空间音乐播放器**。整个产品是一件能在桌面上舒展、收缩、折叠、隐匿的界面：五种形态（完整 / 迷你 / 胶囊 / 贴边 / 隐匿）是同一个窗口、同一份播放状态。

- **音源**：首发不内置任何商业或第三方版权曲库。内置本地音库（安全作用域文件夹书签 + ID3/m4a + `.lrc` 侧车 + Finder 打开）、OpenSubsonic / Navidrome、WebDAV；按 [`FLOW Source Spec v1`](SOURCE_SPEC.md) 支持用户导入第三方 JS 插件（`JavaScriptCore` 沙箱 + `allowedDomains` 白名单，兼容 MusicFree / LX）与声明式 JSON 模板 / 订阅清单。原内置 B 站实现已剥离为未随包分发的 B 站外部插件（开源前已移出仓库、不再分发）。
- **主窗口**：固定侧栏（正在播放 / 首页 / 收藏 / 最近播放 / 歌单 / 离线 / 设置）+ 顶部搜索 + 统一底部播放器；浏览不停止音乐，无当前歌曲时不显示空播放条。菜单栏只做快速操作。
- **右上角三档「普通 / 悬浮 / 沉浸」**：悬浮 = 桌面歌词胶囊，点一下回到普通；沉浸 = 原创 Metal 场景铺满（默认全屏），每拍一道看得见的波。普通页的背景可以换成纯色、封面取色或同一套场景。详见 [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md)。
- **技术栈**：Swift 6（strict concurrency，警告即错误）+ SwiftUI 主导、AppKit 做窗口与菜单栏；播放走 AVFoundation（`HTTPStreamPlayerSession` + `MediaAudioCache` + `ProgressiveAudioStream`），系统媒体信息走 MediaPlayer；持久化 SwiftData + UserDefaults；小组件 WidgetKit + App Intents；避让用 CGWindowList 读可见窗口几何，AX 只做事件通知。
- **隐私与网络**：联网只用于用户配置的自建服务、显式导入并受 `allowedDomains` 约束的插件 / 模板、AMLL / LRCLIB 歌词与封面、设置页 GitHub 自动搜源（`api.github.com` / `cdn.jsdelivr.net`）、FLOW Voice 模型检索与下载（`huggingface.co` / `hf-mirror.com` / `api.github.com`），统一受设置页「允许联网」开关门控（正式版默认开启，测试替身默认关闭）；不录屏、不读输入；沙盒开启；账号与口令只进 Keychain（`KeychainSecretStore`）。

---

## 2. 环境与构建

| 项 | 值（实测） |
|---|---|
| Xcode | 27.2 (27B52)，**没装 Metal Toolchain**（着色器因此写成 Swift 字符串运行时编译） |
| Swift | 6.4.2（`SWIFT_STRICT_CONCURRENCY=complete`，警告即错误） |
| 部署目标 | macOS 14.0+ |
| 工程 | `SpatialLyricsPlayer.xcworkspace`（工作区里只有一个 xcodeproj） |
| 签名 | 本机没有开发者证书，所有命令都要 `CODE_SIGNING_ALLOWED=NO` |

```bash
# 上线前一键验证：单测、架构红线、死代码、Release 0 警告、文档数字
./Scripts/verify.sh            # --quick 跳过 Release 构建；--live 额外跑联网用例

# 单独编译 / 运行
xcodebuild build -workspace SpatialLyricsPlayer.xcworkspace -scheme SpatialLyricsPlayer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/slp-dd CODE_SIGNING_ALLOWED=NO
open -n /tmp/slp-dd/Build/Products/Debug/SpatialLyricsPlayer.app
```

- 联网用例默认跳过。`xcodebuild test` 不会把环境变量透传给测试宿主，所以 `--live` 用文件标记 `/tmp/bili-live-test` 打开（`LiveTestGate` 同时认 `SLP_LIVE_TEST=1` 和这个文件）。
- **没有 WindowGroup**：播放器窗口由 `MorphWindowController` 直接创建并持有；点 Dock 图标回到完整形态（`applicationShouldHandleReopen`）。主窗口之外只有 `Settings` 场景（⌘,）与 `MenuBarExtra`。

### 调试开关（只读环境变量，不进业务判断）

| 变量 | 作用 |
|---|---|
| `SLP_DATA_DIR=<目录>` | **隔离运行**：数据库、缓存、导入插件、偏好设置都落在这个目录（偏好是独立 suite），不碰真实数据 |
| `SLP_QA_DIR=<目录>` | 仅 Debug：启动进程内验收驱动器，往目录里丢 `<序号>.cmd`、读 `<序号>.out`（`App/Debug/QAHarness.swift`） |
| `SLP_DEBUG_PLAY_PATH=<音频文件>` | 启动即打开并播放这个本地文件 |
| `SLP_DEBUG_PLAY=1` | 启动后播放库里第一首（真实播放链路） |
| `SLP_DEBUG_MUTE=1` | 调试播放时音量归零 |
| `SLP_DEBUG_MORPH=expanded\|compact\|capsule\|edge\|dormant` | 启动后切形态（走真实用户意图事件） |
| `SLP_SPATIAL_DEBUG=1` | 形态决策日志 + 变形过程采样打印真实窗口帧 |
| `SLP_DEBUG_SPATIAL=1` | 叠加空间调试面板 / 覆盖层（障碍物、候选区） |
| `SLP_DEBUG_FRAME=1` | 打印 `FRAME gap=`，复核内容重绘节拍 |
| `SLP_DEBUG_TIMING=1` | 打印形态求解与装载耗时 |
| `SLP_DEBUG_DORMANT_HANDLE=1` | 隐匿时保留边缘把手 |
| `SLP_DEBUG_APPEARANCE=light\|dark` | 强制浅 / 深色，截图复核用 |
| `SLP_DEBUG_WALLPAPER_LUMA` / `SLP_DEBUG_WALLPAPER_CONTRAST` | 伪造壁纸亮度与对比，复核"按背景切深浅" |
| `SLP_DEBUG_DRAWER=online\|library\|queue` | 启动即展开对应抽屉 |
| `SLP_SETTINGS_PANE=<分页>` | 设置窗直接落到指定分页 |
| `SLP_REFRESH_RATE=<Hz>` | 覆盖动画时序按的刷新率 |
| `SLP_DISABLE_FADE=1` | 关闭切歌淡变（对比试验） |
| `SLP_AUDIO_TEST=1` / `SLP_TEST_RENDER_DIR=<目录>` | 测试用：开可选的真实音频管线用例 / 把渲染探针图写到目录 |

### 深链

`spatiallyrics://now`（或 `open`）、`spatiallyrics://toggle-floating`、`spatiallyrics://morph/<形态>`、`spatiallyrics://shape/<歌词排布>`。后两个是小组件 / 快捷指令切形态的正式入口。

---

## 3. 代码地图

（2026-11-22 按实际目录统计：Swift 文件数 / 行数）

| 目录 | 文件 / 行数 | 你会在里面找什么 |
|---|---|---|
| `App/` | 4 / 725 | 入口、`AppDelegate`（形态窗口启动、睡眠定时、会议模式、耳机监听、Dock 隐藏）、`Debug/QAHarness`（仅 Debug） |
| `Core/` | 21 / — | 领域模型（`Track`、`LyricsDocument`、播放状态 / 事件 / 错误、沉浸场景与背景枚举）、工具（Keychain、脱敏日志、`RuntimeSandbox`、`AudioFeatureMeter`、`UniversalFileClassifier`） |
| `DI/` | 3 / — | `AppContainer`（含 `voiceDriver` 强持有）、`ContainerBuilder`、`SettingsStoring`（全部设置项的协议与 UserDefaults / 内存实现） |
| `Sources/` | 35 / — | 源协议族与 `SourceManager` / `SourceRegistry`；`Audio/`（流式会话、缓存、边下边播、离线曲库、均衡器、响度、播放抽头与分频、受控 HLS）；`Plugins/`（JS 插件引擎与沙箱、轻量元数据持久化、JSON 模板、GitHub 搜源与预设、`SourceDomainPolicy`、`PluginHTTPClient`）；`Standard/`（本地音库、OpenSubsonic、WebDAV）；`Mock/`（测试与降级模式） |
| `Playback/` | 8 / — | 九态机 + 纯 reducer、协调器（在线失效兜底本地缓存 + Voice 优先接入）、引擎、队列、会话持久化、系统媒体桥接 |
| `Lyrics/` | 17 / 3010 | LRC / AMLL TTML 解析、LRCLIB、歌词缓存与绑定、源感知加载、时间轴、滚动布局、简体归一 |
| `Persistence/` | 24 / 1487 | SwiftData 模型、仓库、迁移 |
| `Integration/` | 24 / — | 外观设置、热键、系统媒体、睡眠定时、淡入淡出、会议模式、耳机、开机启动、深链、备份、诊断、HLS/流桥接、小组件桥 |
| `Morphology/` | 14 / 2427 | **纯逻辑**：形态规格、状态机、决策引擎、连续落点求解、过渡计划、弹簧与刷新率 |
| `Morph/` | 11 / 3503 | **窗口层**：`MorphPanel`、`MorphWindowController`（形态、全屏、沉浸、三档）、`MorphRootView`、`PlayerMode`、空间调试面板 |
| `Spatial/` | 12 / 1257 | 安全区、可见窗口扫描与 AX 观察、空闲区分析、落点评分、贴边 |
| `DesignSystem/` | 6 / — | 令牌（排版 / 颜色 / 材质 / 动效 / 圆角）、基础组件、图标、封面取色、`HairlineSlider`、`FlowSegmentedSwitch` |
| `UI/` | 43 / — | `Expanded/`（主窗口、歌词区、底栏、首页、播放页背景、全域拖放路由）、`Immersive/`（沉浸页、渲染器、四个场景、节拍跟踪、背景画廊）、`Settings/`（设置窗，11 个分区，含自动获取与 GitHub 搜源/Voice 镜像设置）、`Onboarding/`（新手引导层与锚点上报）、`Voice/`（音色图标、原曲↔AI 切换胶囊、在线音色获取面板、参数面板）、`Floating/` `Compact/`（悬浮形态）、`Bilibili/`（兼容保留的通用歌单 / 歌曲列表状态） |
| `MenuBar/` | 1 / 296 | 菜单栏面板 |
| `Overlay/` `System/` `Shared/` | 3 / 102 · 2 / 248 · 3 / 215 | 歌词排布与透明度；壁纸亮度与背景外观；主应用与小组件共享的 App Group 快照 |
| `SpatialLyricsWidgets/` | 2 / 211 | 小组件 |
| `Tests/` | 188 / — | 单元测试（含默认跳过的联网用例）；`UITests/` 1 个冒烟测试，没有签名身份跑不了 |
| `Voice/` | 25 / — | **纯原生 AI 翻唱**：`ORTSession`（`OnnxRuntime.xcframework`）、`VoiceAudioDSP`（`Accelerate` + `AVFoundation`）、MDX 人声分离、RMVPE / HuBERT / RVC ONNX 推理、`ONNXSineGenSanitizer` 相位修复、`.f32bin` k-NN 检索、三级缓存、音色包与模型在线获取、播放驱动、容器装配 |
| `Tools/rvc-converter/` | —（Python 离线工具） | 独立 CLI 转换器（未打包进 App）：社区 `.pth` + `.index` -> `.voicepack` 与基础 ONNX 导出 |
| `external-plugins/` | — | 未随包分发的 B 站插件与三个 JSON 模板示例 |

单向依赖：`App/Morph/UI/MenuBar → Morphology/Spatial/Lyrics/Playback → Sources/Persistence → Core`，`Scripts/architecture-lint.sh` 拦违反项；`Scripts/dead-code-scan.py` 拦零引用类型。

---

## 4. 必须知道的架构决策

1. **播放状态是九态机 + 纯 reducer**（`(state, [Effect], accepted)`）。没有 `isPlaying/isLoading/isBuffering` 这种可以自由组合的布尔。
2. **进度靠 `PositionAnchor(position, hostTime, rate)`**，不起定时器；`rate = 0` 冻结在暂停位置。
3. **空间布局求"能不挪就不挪"**，不是"总是最大矩形"：决策带防抖、吸附距离、最小改进量与形态冷却（现行数值与链路见交接日志第 9、12、14 节）。
4. **五种形态是同一个 NSPanel**。双窗口在交叠时必然出现重影 / 闪白 / 抢焦点。`MorphologyEngine` 决定形态、`WindowGeometryResolver` 决定矩形、`MorphologyStateMachine` 决定允不允许变，窗口层用 AppKit 帧动画做连续插值。**不要退化成"关一个窗口、开另一个窗口"**。沉浸也不是新窗口，而是完整形态上的一个标志（`MorphPresentationModel.isImmersive`）。
5. **元信息补全不进关键路径**：`PlaybackEngine.load` 立刻用原曲目装载，歌名 / 歌手 / 封面在后台补，回来通过 `metadataRefreshed` 替换（先 `await` 再装载曾让每次点歌多等 146ms）。
6. **状态机与窗口必须同步**：自动变形被窗口层否决时，必须 `machine.assumeMorphology(from)` 把状态机拉回去，否则下一次用户点击会被判成 `redundant`——表现就是"点胶囊不展开"。
7. **音源只通过 `SourceManager` 接入**：表现层不认识任何具体源；插件只能访问自己声明的 `allowedDomains`，插件**元数据请求**走 `PluginHTTPClient` 统一校验（2026-11-20 代码审查后收口）。2026-11-22 已将 HTTP 音频与 HLS 子请求纳入策略：HLS 使用仅监听回环地址的受控代理，列表/分片/密钥逐跳校验，跨源剥离认证头，动态检查联网开关；不再由 AVFoundation 直接访问外网。验收与限制见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。
8. **沉浸画面全部是运行时编译的着色器**：Metal 源码写在 Swift 字符串里，单测会把每个场景在真实 GPU 上编一遍并离屏渲染；不要加 `.metal` 文件（本机 Xcode 没有离线编译器，整个工程会编不过）。
9. **AI 翻唱已全面原生化（零 Python 运行时）**：`Vendor/OnnxRuntime/OnnxRuntime.xcframework`（1.32.0）+ `Voice/Runtime/ORTSession.swift` + `Voice/Audio/VoiceAudioDSP.swift` 直接在工作线程跑 ONNX Runtime 与 `Accelerate/vDSP`，并通过 `OrtRunOptionsSetTerminate` 原生取消；模型资产位于 `~/Library/Application Support/FLOW/Voice/Models`。社区 `.pth`/`.index` 需先经 `Tools/rvc-converter/` 离线转为安全 `.voicepack`。详见 [FLOW_VOICE.md](FLOW_VOICE.md)。

### 4.1 形态状态的四个维度（不要合成一个布尔）

| 维度 | 位置 |
|---|---|
| 用户请求的形态 | `MorphologyState.current` |
| 系统推荐的形态 | `MorphologyState.recommendation` |
| 当前实际展示的形态 | `MorphologyState.current`（与 `MorphPresentationModel.morphology` 同步） |
| 动画中的目标形态 | `MorphologyState.previous` + `phase == .transitioning` |

优先级：系统挂起 > 用户隐藏 > 用户锁定 > 用户主动展开 > 用户指定形态 > 空间优化。沉浸期间所有非用户发起的收缩一律拒绝。

---

## 5. 验证现状

- **怎么验**：`./Scripts/verify.sh` 全绿才算通过；它同时核对文档里的测试条数、证据图张数与 Release 警告数（`Scripts/check-doc-numbers.sh`）。
- **基线数字**：见 [上线清单](RELEASE_CHECKLIST.md) 第一节与 [`evidence/coverage.txt`](evidence/coverage.txt)。
- **实测证据**：
  - 五形态、连续变形、避让、深浅色等：[运行时证据](RUNTIME_EVIDENCE.md) 与 `screenshots/flow/`；
  - 沉浸模式、节拍联动、三档切换、播放页背景（含真实歌曲、Release 性能、真实点击路径）：[IMMERSIVE_MODE.md](IMMERSIVE_MODE.md) 第九、十节；
  - 多音源与 GitHub 真实插件的联网端到端验证：交接日志第 214–215 节。
  - FLOW Voice 原生端到端转换：纯 Swift + `OnnxRuntime.xcframework` + `Accelerate` 跑通 `rmvpe.onnx` + `hubert_base.onnx` + `f0G40k.voicepack`；支持 `RunOptionsSetTerminate` 实时取消、Gapless 预热与无源离线 AI 起播。数据与限制见 [FLOW_VOICE.md](FLOW_VOICE.md)。
- **没有验证（别当成已完成）**，完整清单与原因见 [已知限制](KNOWN_LIMITATIONS.md)：
  - UI 测试（没有签名身份，一条都没跑过）、小组件真机添加、开机启动注册；
  - 多显示器热插拔、全屏应用前的隐藏（场景 D）；
  - 媒体键 / 控制中心、VoiceOver 人工走查、系统「减少动态效果」下的实机表现、真拔耳机；
  - 沉浸模式：2× 屏上四个场景的全屏画质评审、全屏状态下用真实点击切「普通」。

---

## 6. 工程陷阱（踩过，记下来）

1. **目录同步组**：`project.pbxproj` 用 `PBXFileSystemSynchronizedRootGroup`。新建**顶层**目录必须登记，否则文件不参与编译而 `xcodebuild build` 依然报成功；子目录里的新文件会自动进编译。反过来，**登记了的目录不能是空的**：git 不收空目录，干净检出时目录不存在，架构红线与死代码扫描会直接失败（2026-11-21 因此删掉了一直为空的 `Privacy/`）。
2. **`Foundation.Morphology` 已存在**（macOS 12+）：自己的类型叫 `Morphology` 会在测试 target 里 `ambiguous for type lookup`。现名 `PlayerMorphology`。
3. **无边框窗口不能透桌面**：完整形态用不透明底色（明确 RGB），只有悬浮形态才磨砂；`NSColor.windowBackgroundColor` 在自定义窗口里不可靠，浅色下会落成纯白。
4. **Finder 的桌面是一个铺满全屏的 AX 元素**（`AXScrollArea / AXDesktop`）：不过滤会让播放器一切走就隐匿。`WindowGeometryReader.isObstacleCandidate` 是唯一入口。
5. **`HairlineSlider` 的 range 默认 0…1**：进度条要传 `range: 0...duration`。
6. **`open -a <app> <url>` 会触发 reopen**：`applicationShouldHandleReopen` 无条件展开会把刚切到胶囊的窗口拉回来，现在用 `allowsActivationExpansion` 压 2 秒。
7. **位置记忆优先于设置**：`PlacementSnapshot` 会覆盖 `defaultShape`；调试钩子必须排在恢复之后。
8. **没有固有尺寸的东西会撑满父容器**：裸 `Path`、`NSViewRepresentable` 放进 `.overlay` 会占满整块区域、盖住所有按钮。必须显式 `.frame`。排查：把窗口 AX 树打出来看每个元素的真实 frame。
9. **`.nonactivatingPanel` 让应用永不激活**，而 `Button` 在非激活应用里不响应点击。只有悬浮形态用它；完整形态要能被一次点击激活。
10. **`NSHostingView` 会抢窗口尺寸**：手动改窗口尺寸时要 `hosting.sizingOptions = []`，否则拖拽缩放必崩（`more Update Constraints passes than there are views`）。
11. **跟着窗口移动的手柄不能用 SwiftUI 手势**：位移会被抵消，用 NSView + `NSEvent.mouseLocation`。
12. **`unregister` 的作用域要跟名字一致**：`HotkeyCenter` 曾在注销单个动作时清空全部 Carbon 引用，连续注册三个快捷键只剩最后一个。
13. **删目录前先 `ls -R`**：`rm -rf` 曾删掉整个 `Tests/Support`。删源时要连"只被引用、没有测试"的组件一起查（曾误删 `KeyboardOffsetMonitor`）。
14. **有几类测试检查的是源码文本**：`ArchitectureBoundaryTests`（注释里写 `AVPlayer`、`DispatchQueue` 也会变红）、`LyricAccessibilityActionTests`（匹配 `LyricScrollView` 里的调用写法）等。重构这些文件时要同步改测试里匹配的字符串。
15. **NSPanel 默认不参与全屏**：完整形态要显式声明 `.fullScreenPrimary`，否则 `toggleFullScreen` 静默无效；全屏期间不要改 frame、不要保存窗口位置。
16. **`MTAudioProcessingTap` 给的缓冲起点时间是量化过的**（每次 960 帧，起点跳 ±11.6ms）：按它切起音格会让节拍速度读错（《七里香》142 读成 85 / 114）。按采样数连续推进，只在跳变超过 0.1 秒时重新对齐。
17. **`xcodebuild test` 不透传环境变量给测试宿主**：要切换测试行为用文件标记（见第 2 节的 `--live`）。
18. **zsh 不按空格拆变量**：脚本里 `for f in $LIST` 不会逐个遍历，用数组。
19. **外部 B 站插件的老坑**（原内置源时代踩过，写插件时仍适用）：B 站返回的 URL 常是协议相对的 `//…`，`URLSession` 报 `-1002`，要补 `https:`；音频缓存文件要叫 `.m4a`，AVPlayer 靠扩展名判容器；`nav` 游客态返回 `-101` 但 `data.wbi_img` 仍有签名密钥；收藏夹接口必须带 `up_mid`，漏了返回 `-400`。
20. **容器层 `[weak driver]` 回调必须配显式强引用**（2026-11-22 踩过）：`VoiceContainer.attach` 中的 `VoicePlaybackDriver` 只被测试局部强持有时能跑，真机走 `ContainerBuilder.make` 出作用域立刻释放成 `nil` 导致点击「播放 AI 版」完全无反应。凡是由子容器传出的 `[weak driver]` 协作者必须在 `AppContainer` 上保留 `let` 属性并在真容器测试里做跨作用域回归验证。
21. **JS 插件跨重启/切回原曲必须保留 `_item` 并兜底老库 `bvid`**（2026-11-22 踩过）：重启后先播 AI 版或恢复队列时内存 `rawItemCache` 为空，`JSPluginSource.rawDictionary` 若只靠 `externalID` 不保留 `bvid`/`aid`/`cid`，社区插件调用无参详情接口必掉源。`Track.persistentIdentifier` 与历史库 `BV`/`aid` 提取及 `PlaybackCoordinator` 切原曲本地缓存兜底不可删除。

---

## 7. 实机验收手段

- **隔离启动**：`SLP_DATA_DIR=<目录> SLP_QA_DIR=<目录> <app>/Contents/MacOS/SpatialLyricsPlayer`。隔离目录里的设置会一直留到下次启动（偏好 suite 名由目录路径摘要决定），换进程照样生效。
- **驱动器常用指令**：`state`、`windows`、`play <路径>`、`mode normal|floating|immersive`、`player-background <名>`、`immersive-fullscreen on|off`、`immersive-state`、`immersive-beats`、`shot`、`key`、`scroll`、`quit`。驱动器注入的 `click` 对主窗口里的 SwiftUI 按钮不生效，真实点击用 Computer Use 按无障碍元素点。
- **Metal 画面截图**：驱动器的 `shot` 拍不到 Metal 层，用 `windows` 取窗口号再 `screencapture -x -o -l <窗口号>`。
- **性能一律用 Release 测**：Debug 下自家音频代码未优化，CPU 读数虚高。Release 没有驱动器，用 `defaults write <隔离 suite> <键> <值>` 改设置、`SLP_DEBUG_PLAY_PATH` 启动即播。
- **别在别人正在用的机器上反复进全屏**：全屏会接管整块屏幕，用户一切走全屏就可能被打断。全屏只验进入，其余路径用窗口模式测。

---

## 8. 接手后第一步建议

1. `./Scripts/verify.sh`，确认基线和上线清单一致；
2. 隔离启动一份 Debug 版，播一首本地歌，依次点右上角「悬浮」「普通」「沉浸」，再打开「背景」画廊换几个场景——这是理解窗口层最快的路径；
3. `SLP_SPATIAL_DEBUG=1` 启动，`open -g -a <app> "spatiallyrics://morph/capsule"`，看日志里的 `TRACE frame=` 序列，理解形态与避让；
4. 本轮播放与受控 HLS 已通过发布门禁；继续处理签名、公证、最终包验收、FLOW Voice 全曲听感与剩余审计项，当前缺口以 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) 为准；
5. 下一步做什么见 [NEXT_STEPS.md](NEXT_STEPS.md)。

---

## 9. 现行实现规则在哪里

交接日志按时间追加，同一件事改过多轮。下面这些章节写的是**现在仍然有效**的规则，改相关代码前先读：

| 主题 | 出处 |
|---|---|
| 主窗口契约：真标题栏、关闭 = 收进菜单栏、全屏期间跳过自动布局 | 交接日志第 7.5 节 |
| 变形 / 遮挡响应：后台单次求解、拖动期间响应、恢复唤醒 | 交接日志第 9 节 |
| 按背景自动切换深浅 | 交接日志第 10 节、[BACKGROUND_APPEARANCE.md](BACKGROUND_APPEARANCE.md) |
| 移动与躲避的卡顿 | 交接日志第 12 节、[SPATIAL_RESPONSIVENESS.md](SPATIAL_RESPONSIVENESS.md) |
| 决策与动画分离 | 交接日志第 14 节 |
| 适配所有刷新率 | 交接日志第 16 节 |
| 阻尼弹簧过渡 | 交接日志第 18 节 |
| 多音源架构与 `FLOW Source Spec v1` | 交接日志第 214–215 节、[SOURCE_SPEC.md](SOURCE_SPEC.md) |
| 沉浸模式、节拍联动、三档切换、播放页背景 | [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md) |
| FLOW Voice：原生推理链路、三级缓存、模型目录、在线获取与精选卡片 | [FLOW_VOICE.md](FLOW_VOICE.md) |

---

## 10. 最近的改动（2026-11-20 – 11-22）

> [!IMPORTANT]
> **本轮核心重点（2026-11-22 晚 · AI 翻唱与原曲互切闭环）**：
> 1. **杂音根治 + 完整原声获取**：`VoiceModelAssetsManager` 校验拦截原版 HuBERT 误装、`ONNXSineGenSanitizer` 运行时修正 `SineGen` 相位阈值 `-0.5`、`OfflineLibraryManager.ensureCachedAudioFileURL` 等待在途流完整落盘后再推理。
> 2. **「播放 AI 版」无响应根因**：[`AppContainer`](../DI/AppContainer.swift) 显式强持有 `voiceDriver: VoicePlaybackDriver?`，防止 [`VoiceContainer`](../Voice/Integration/VoiceContainer.swift) 中的 `[weak driver]` 回调脱离局部作用域后立刻变 `nil`；补充 `pendingExplicitAutoplayTrackKey` 避免并发重载吞掉自动起播。
> 3. **切回原曲掉源与界面修复**：[`JSPluginEngine`](../Sources/Plugins/JSPluginEngine.swift) 轻量化持久化 `_item` 并为历史库（`NULL`）提取 `BV`/`aid` 兜底、自动将 `http://*.hdslb.com` 封面升为 HTTPS（防 `-1022 ATS`）；[`PlaybackCoordinator`](../Playback/PlaybackCoordinator.swift) 在线取流失效时无缝兜底 `MediaAudioCache` 本地缓存；[`FlowSegmentedSwitch`](../DesignSystem/FlowSegmentedSwitch.swift) 与 [`TransportBand`](../UI/Expanded/TransportBand.swift) 彻底消除胶囊文字被压成 `... | ...`。
> 详见 [FLOW_VOICE.md](FLOW_VOICE.md) 与 [RUNTIME_EVIDENCE.md](RUNTIME_EVIDENCE.md) 第 11 节。
- **发布收口（11-22）**：修复播放 P2-1…P2-8，统一稳定身份、异步 effect 与会话代数、取消复位、seek 结束、单曲循环手动切歌及自然续播任务交接；HLS 改用仅监听回环地址的受控代理，列表/分片/密钥逐跳校验域名与联网开关，跨源剥离秘密头，限制响应与并发。默认全量门禁与真实音频/联网专项均通过，证据见 [发布清单](RELEASE_CHECKLIST.md) 和 [验收记录](evidence/release-2026-11-22.txt)。旧审计的发现数量是历史快照，剩余限制以 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) 为准。

- **自动避让与冷启动检测全链路修复**（11-22，回归测试在 `AutoAvoidanceReliabilityTests`）：
  - `start()` 冷启动预热后台窗口扫描，`restorePreferences()` 增加 `userIntentSeq` 守卫防止异步恢复覆盖用户刚切换的形态，并在恢复悬浮态时携带实时障碍物快照求解初始落位；
  - `compensatingCheck()` 在本应用处于前台但窗口为非 `.expanded`（悬浮/贴边/隐匿）时同样定时巡检，且在仍与障碍物冲突但尚未针对当前指纹完成避让尝试时自愈重算；
  - `performEvaluation()` 拆开受遮挡紧急让位（`displaced`）与主动舒展（`opportunityReady`），`displaced` 不受 `userMorphUntil` 6 秒保护期与 `opportunityGate` 500ms 延迟限制，并通过 `resolveSameMorphologyTarget` 在跨形态建议或锁定时做同形态兜底避让；
  - `evaluateSpace(immediate:geometryOnly:)` 分离状态意图版本 `spatialSeq` 与纯外部几何变动补算，消除连续拖窗下的评估饥饿；动画期间挂起 `deferredEvaluationPending` 并在看门狗/动画收尾时统一复位补算。
- **音源自动获取与扩展预设收拢、FLOW Voice 自动获取及全应用降门槛**（11-22）：
  - 设置页整合「自动获取与扩展预设」（`GitHubSourceDiscovery` 自动搜源 + 社区扩展与开放 API 预设按需一键获取 + `raw.githubusercontent.com -> cdn.jsdelivr.net` 回退），首页空态保持纯净合规、不暴露特定站点开关；
  - FLOW Voice 支持三底座模型（`rmvpe.onnx`、`hubert_base.onnx`、`UVR-MDX-NET-Voc_FT.onnx`）一键补齐与首次任务按需自动获取，支持 HuggingFace 社区 RVC 音色在线检索、直连下载自动转包导入及默认国内镜像（`hf-mirror.com`）；
  - 主窗口新增全域拖放路由器（`UniversalDropRouter`，支持音频/文件夹/歌词/插件/音色模型）、无歌词显式快捷搜词与多编码本地导入、以及联网/辅助功能权限就地引导。
- **多音源重构**（11-20，交接日志第 214–215 节）：内置本地音库 / OpenSubsonic / WebDAV，JS 插件与 JSON 模板导入，B 站源剥离为外部插件，多个 GitHub 真实插件联网端到端验证。
- **代码审查修复**（11-20 – 21，提交 `fix(plugins,sources,audio)`，回归测试在 `ReviewFixRegressionTests`、`PluginNetworkingTests`、`ProgressiveAudioStreamIOTests`、`StandardSourcesTests`）：
  - 插件网络请求统一走 `PluginHTTPClient`，篡改过的持久化流地址会被域名策略拒绝；
  - 未缓存的服务器曲目可以显式下载，离线保存保留插件提供的歌词，本地文件离线保存不走网络；
  - 旧版带音质后缀的缓存键自动提升、只在用过后缀的源里查；
  - 保存的音质在控制器创建前就生效并同步到所有源；添加服务器时的连接测试遵守「允许联网」开关；
  - 沙盒补上 `network.client` 权限；首页空态「前往设置导入音源」直接落到「在线音乐」页。
- **沉浸播放模式**（11-21，提交 `feat(immersive)`）：四个原创场景、封面取色、随音乐变化、实时节拍跟踪与每拍一道波、焦点四行歌词与间奏点；右上角三档切换；普通页背景与背景画廊；普通页封面与歌词居中并随窗口按比例放大。设计、实测数字与实机发现的问题见 [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md)。
- **FLOW Voice**（11-21 重构为纯原生 Swift + ONNX Runtime）：移除 Python worker 与 `.pth` 运行时，内嵌 `OnnxRuntime.xcframework`（1.32.0）与 `AVFoundation` + `Accelerate/vDSP` 原生管线；新增 `Tools/rvc-converter/` 离线转 `.voicepack`/`.f32bin`、三级缓存、安全作用域导入、`PlaybackCoordinator` Gapless/离线支持与端到端 ONNX 合成实测。详见 [FLOW_VOICE.md](FLOW_VOICE.md)。
- **工程整理**（11-21）：`.gitignore` 补凭据与构建产物、`verify.sh` 判定加严、删掉空的 `Privacy/` 分组；文档归档进 [`archive/`](archive/README.md)，交接文档拆成本文 + 交接日志。
- **全量代码审计**（11-21）：219 个生产文件逐层审计 + 文档逐份核对 + 构建/测试基线独立复核。无 P0；**P1×10**（插件音频数据面绕过域名策略、`safeKey` 缓存键碰撞、插件 `setTimeout(Infinity)` 宿主崩溃、OpenSubsonic 容器/缓存档、WebDAV 凭据可外发、备份恢复只试最新一份、冷启动 `saveNow` 覆盖恢复、本地曲目误把整段音频当 LRC、恢复默认布局状态脱节、悬浮透明度污染完整播放器）、P2×38、P3×9。逐项证据与修复顺序见 [CODE_AUDIT_2026-11-21.md](CODE_AUDIT_2026-11-21.md)，收口优先级见 [NEXT_STEPS.md](NEXT_STEPS.md) 第 0 节。

---

## 11. 文档地图

现行文档见 [README 第 7 节「文档地图」](../README.md#7-文档地图)；历史报告、评审与 B 站时代资料见 [`archive/`](archive/README.md)。
