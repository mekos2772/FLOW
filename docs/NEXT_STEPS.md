# 下一步（据实，按优先级）

> 刚接手先读 [交接文档](HANDOVER.md)。下文的"HANDOVER 第 N 节"指 [交接日志](archive/HANDOVER_LOG.md) 的同一节。
> 口径：只有"已实测/已截图"的才标 `[x]`；未做的统一标 `[ ]`。

## 已完成（截至 2026-11-22）

- [x] **悬浮自动避让与冷启动检测稳定性修复**（2026-11-22）：`start()` 冷启动预热后台窗口扫描，`restorePreferences()` 增加 `userIntentSeq` 守卫并在恢复悬浮态时携带实时障碍物求解初始落点；`compensatingCheck()` 在本应用处于前台但窗口为非 `.expanded` 时同样定时巡检并支持冲突自愈；`performEvaluation()` 解耦受遮挡紧急让位（`displaced`，无视 6 秒 `userMorphUntil` 与 500ms `opportunityGate`）与同形态兜底求解（`resolveSameMorphologyTarget`）；`evaluateSpace(immediate:geometryOnly:)` 避免外部几何事件递增 `spatialSeq` 引发饥饿；动画期间挂起 `deferredEvaluationPending` 并修复看门狗早退。由 `AutoAvoidanceReliabilityTests` 6 项回归测试覆盖。
- [x] **音源自动获取与扩展预设收拢、FLOW Voice 模型/音色自动获取与全应用降门槛**（2026-11-22）：设置页整合「自动获取与扩展预设」（GitHub 自动搜源 + 社区扩展/开放 API 预设一键或按需获取 + jsDelivr CDN 回退，首页空态保持纯净合规）；FLOW Voice 支持三底座模型（`rmvpe.onnx` / `hubert_base.onnx` / `UVR-MDX-NET-Voc_FT.onnx`）一键自动获取、在线 RVC 音色检索直连下载自动导入及默认国内镜像（`hf-mirror.com`）；主窗口支持全域文件拖放（`UniversalDropRouter`）、无歌词快捷搜词/多编码导入及权限就地引导。
- [x] **【本轮重点】FLOW Voice 全链路杂音根治与原曲↔AI 双向热切加固**（2026-11-22）：`VoiceModelAssetsManager` 校验拦截原版 HuBERT 误装、`ONNXSineGenSanitizer` 运行时修正常量根除静音后锁频杂音、`OfflineLibraryManager.ensureCachedAudioFileURL` 等待在途流完整落盘；`AppContainer.voiceDriver` 强持有防止 `VoiceContainer` `[weak driver]` 悬空释放并消除并发起播竞态；`JSPluginEngine` 轻量化持久化 `_item`/历史 `BV` 字段与 `hdslb.com` 封面升级 HTTPS、`PlaybackCoordinator` 在线失败回退本地缓存、底栏切换胶囊窄宽自适应防 `...` 截断。由 `VoicePipelineIntegrationTests` 与 `PluginImporterTests` 新增回归覆盖并在 Release 真机完成全曲生成与切换实测。
- [x] **FLOW Voice（纯原生 AI 翻唱重构）**（2026-11-21）：彻底移除 Python worker 与 `.pth` 运行时，改为内嵌 `OnnxRuntime.xcframework`（1.32.0，CoreML + CPU EP）与 `AVFoundation` + `Accelerate/vDSP` 全原生推理；提供离线转换工具 `Tools/rvc-converter/`（`.voicepack` + `.f32bin`）；打通三级缓存、`PlaybackCoordinator` 离线 AI 起播与 Gapless 预热、安全作用域导入、真实参数控制及本地端到端 ONNX 合成实测。见 [FLOW_VOICE.md](FLOW_VOICE.md)。
  - [ ] 扩大多首真实含伴奏曲目与 `v1` / `32k` / `48k` 社区音色包的主观测听覆盖；
  - [ ] 音色面板与设置页模型资产管理全套辅助功能（VoiceOver）人工走查。
- [x] **沉浸播放模式**（2026-11-21）：四个原创 Metal 场景 + 封面取色 + 随音乐变化 + 焦点歌词与间奏点，真实界面点击验收与 Release 性能实测，见 [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md)。
  - [x] 实时节拍跟踪与每拍一道波（节拍联动四档可调）；右上角「普通 / 悬浮 / 沉浸」三档；普通页背景与背景画廊；普通页封面与歌词居中并按窗口比例放大；
  - [x] 三首真实歌曲与专辑封面复核、2× 屏窗口截图；
  - [ ] 2× 屏下四个场景的全屏画质评审、系统「减少动态效果」开关下的实机复核、纯音乐 / 古典 / 电子乐与白底极简封面；
  - [ ] 搁置的"火车驶过大桥"场景若要重启，需要先解决云海 / 山体的材质与体积感。
- [x] **主窗口改版**：固定侧栏导航、顶部搜索、浏览/播放分离、歌单嵌入内容区、统一底部播放栏、原生最小窗口 780×480、严格歌曲元数据确认（隐藏未确认条目与原始标题）。
- [x] **形态与空间系统**：五形态单窗口连续变形、连续二维布局、背景深浅自动判色、悬浮歌词随卡片尺寸自适应、自动收缩/避让与隐匿策略。
- [x] **代码审查 P0/P1/P2 全量闭环**：
  - [x] 默认滚动歌词与编辑式歌词隐私/会议遮罩修复；
  - [x] 「允许联网」开关双向门控（动态注册/注销在线源，离线保留本地缓存歌词）；
  - [x] 退出时队列多批曲目有序落库等待（`PlaybackSessionPersistence`）；
  - [x] **播放恢复与电台调度通用化**：`PlaybackRecoveryDriver` 与 `RelatedRadioDriver` 解耦具体平台并支持断流恢复保留暂停意图、跨连续失败保留播放断点；
  - [x] **本地已缓存音频免接口直播**：`MediaAudioCache.cachedAudio(cacheKey:matching:)` 按请求档位直接命中磁盘缓存音频（支持多容器扩展名），跳过远端取流接口，断网或升档失败时支持本地已有缓存降级续播；
  - [x] **AMLL 逐字 TTML 文件落盘缓存**：`AMLLLyricsProvider` 在 `amll-ttml/` 持久化缓存已解析的 `.ttml` 文件，二次播放零网络请求且离线可用；
  - [x] **显式离线下载 / 离线曲库与歌单管理**：`MediaAudioCache` 新增独立永久离线目录 `OfflineAudio/` 免疫 500 MB LRU 淘汰与临时缓存清理；`OfflineLibraryManager` + `manifest.json` 持久保留曲目元数据并预拉封面/歌词；主页侧栏新增「离线」分区、支持单曲/收藏全部离线/歌单离线保存/设置页查看与清理；关闭「允许联网」注销在线源后，`PlaybackCoordinator.offlineSessionFactory` 与 `SourceAwareLyricsLoader.offlineFallback` 仍可直接离线播放与展示简体歌词及封面。
  - [x] **通用响度自动平衡 + 5 段均衡器（EQ）**：`LoudnessAnalyzer` 基于 `AVAssetReader` 离线测量活跃 PCM 响度（跳过 `-55 dBFS` 静默段）与峰值安全增益，经 `LoudnessCache` 持久化到 `loudness-v1.json`；`EqualizerDSP` 实现 5 段（`60 Hz` / `230 Hz` / `910 Hz` / `3.6 kHz` / `14 kHz`）RBJ Biquad 滤波器、6 套预设与软膝限幅（`<= 0.99`）；`AudioProcessingTap` 通过 `MTAudioProcessingTap` 挂入 `HTTPStreamPlayerSession`，既允许响度上推至 `1.8x` 也不干扰 `PlaybackEngine.outputGain` 0...1 淡变/睡眠定时。
  - [x] **边下边播、HLS `.m3u8` 直连与无缝切歌（Gapless）**：`ProgressiveAudioStream` + `StreamingResourceLoaderBridge`（`AVAssetResourceLoaderDelegate`）支持 HTTP `206` 首片快速起播、随机寻址与 `.part` 原子落盘回填缓存，`MediaAudioCache.sniffAudioExtension` 按响应字节魔数自动识别 `flac`/`mp3`/`aac`/`ogg`/`opus`/`wav`/`m4a`，`RemoteStreamSessionFactory` 对 `.m3u8` HLS 流直连 `AVURLAsset`；`PlaybackCoordinator.prewarm` + `PlaybackEngine` 后台预热下一首会话并在自然切歌时免淡入零停顿晋升（`markGaplessNext`）。
- [x] **多音源可导入化重构与多配置兼容标准（`FLOW Source Spec v1`）**：
  - [x] **零预置商业曲库 + 三类内置标准源 + B 站外置抽离**：`SourceManager` 统一管理 **本地音库**（安全作用域书签 + ID3/m4a + `.lrc` 侧车 + Finder 打开）、**OpenSubsonic / Navidrome**、**WebDAV**；原 B 站实现剥离为未随包分发的 B 站外部插件（开源前已移出仓库、不再分发），干净启动后按「尚未配置音源」引导导入；
  - [x] **第三方 JS 插件与 JSON API / 订阅多配置兼容**：制定 [SOURCE_SPEC.md](SOURCE_SPEC.md)，`JavaScriptCore` 隔离沙箱（`JSPluginEngine` / `JSPluginSandboxSupport`）支持 CommonJS / TS `__esModule` / Parcel 多导出、`axios`、`crypto-js`、`cheerio`、`he`、`dayjs`、`qs`、`big-integer`、`webdav`、`userVariables`、LX `globalThis.lx`、OAuth1 `CFBoolean`/RFC 3986 参数编码、音质降级回退；支持 `flow-source-v1` / `flow-server-v1` / GitHub/社区 `plugins.json` 订阅导入与 `SLP_LIVE_TEST=1` 多仓库 GitHub 真实源端到端实测通过。
- [x] **第二阶段先导交付（歌词多行折行与外文双语对照）**：
  - [x] **逐字高亮歌词支持多行折行**：[LyricsDocument.swift](../Core/Models/LyricsDocument.swift) 新增 `LyricWordRun` 与 `LyricWordHighlight.runs(for:at:)`（合并连续已唱/未唱片段并插值当前活跃分字），[LyricScrollView.swift](../UI/Expanded/LyricScrollView.swift) 以 `LyricWordHighlight.attributedString(for:at:)` + `Text(...)` 替换 `lineLimit(1)` / `.mask(Rectangle())`，统一行容器 `row(...)` 支持主歌词多行自然折行与 `lineLimit` 控制，并在 [LyricFieldView.swift](../UI/Expanded/LyricFieldView.swift) 同步支持多行折行。
  - [x] **外文歌双语对照歌词开关**：`LyricLine` 新增 `translation`、`romanization`（向后兼容 `Codable`）及 `translationText(showingTranslation:)`；`AMLLTTMLParser` 通过栈式 `IgnoredRole` 保留顶层 `x-translation`（统一经 `TextNormalizer.simplified` 转简体并保留日文原文）与 `x-roman` 且不污染主文本及分词时间，`LRCParser` 支持将非 CJK 主句同时间戳中文第二行绑定为 `translation`；`LyricScrollLayout` 计入译文显示高度；新增 `showLyricTranslation` 设置项（默认开启）、备份恢复与 `MorphPresentationModel` / `MorphWindowController` 同步，在主歌词顶部栏/右键菜单、悬浮双行/面板视图与上下文菜单及设置页提供「显示中文译文」切换。
  - [x] **歌词手动搜词与持久化绑定**：[AMLLLyricsIndex.swift](../Lyrics/AMLLLyricsIndex.swift) 与 [AMLLLyricsProvider.swift](../Lyrics/AMLLLyricsProvider.swift) 支持多关键词/歌手分词搜索（本地已缓存索引离线可用）及读取原 XML；[LRCLIBSource.swift](../Lyrics/LRCLIBSource.swift) 扩展 `/api/search?q=` 与 `rankManual` 排序；[LyricBindingStore.swift](../Lyrics/LyricBindingStore.swift) 按 `TrackIdentity` 在 `Application Support/FLOW/LyricBindings/` 持久化存储 `.lrc`/`.ttml` 原文（保留逐字与双语信息）并在 [SourceAwareLyricsLoader.swift](../Lyrics/SourceAwareLyricsLoader.swift) 作为最高优先级加载；[LyricVariantCoordinator.swift](../Lyrics/LyricVariantCoordinator.swift) 与 [LyricVariantMenu.swift](../UI/Expanded/LyricVariantMenu.swift) 在右键 Popover 提供歌名/歌手搜索框、来源标识、已绑定状态展示与「恢复自动」解除绑定。
- [x] **当前验证基线**：见 [上线清单](RELEASE_CHECKLIST.md) 与 [coverage.txt](evidence/coverage.txt)；`verify.sh` 全绿（单测、架构、死代码、Release 0 警告、文档数字）。

---

## 0. 2026-11-21 全量代码审计收口（最优先，未完成）

> 逐项证据与建议见 [CODE_AUDIT_2026-11-21.md](CODE_AUDIT_2026-11-21.md)；汇总见 [AUDIT_REPORT.md](AUDIT_REPORT.md) 第〇节。
> 审计结论：无 P0；P1×10、P2×38、P3×9。按下列顺序收口，不要按出现顺序修。

- [x] **插件网络边界**：HTTP 音频逐跳检查域名与联网开关；HLS 通过 `HLSResourceLoaderBridge` / `HLSResourceClient` 将列表、分片、初始化片段和密钥统一接入 `PluginHTTPClient`，跨源只保留通用播放请求头；本机代理仅监听 `127.0.0.1`，资源路由用 HMAC 认证，限制并发和响应大小，不支持的动态网络扩展拒绝加载。WebDAV 保持同源限制（P1-1、P1-5、P2-14）。
- [x] **缓存键与容器格式**：`MediaAudioCache` 新增 SHA-256 防碰撞 `uniquePrefix`（P1-2）；`OpenSubsonicSource` `format=raw` 分离 `.auto`/`.lossless`/`.hiRes` `qualityID` 且支持 `ProgressiveAudioStream` 首片容器魔数嗅探与 `StreamingResourceLoaderBridge` UTI 匹配（P1-4）；补齐 `aiff`/`aif`/`alac`（P3-4）。
- [x] **宿主可用性与原生推理安全**：`scheduleTimer` 拦截 `Infinity`/`NaN` 并钳制有限延迟（P1-3）；`ORTSession` `ORTEnvironment` 消除 5 处 `fatalError` 改为可恢复 `throws`。
- [x] **数据恢复与本地歌词**：损坏库文件头分支复用全备份新→旧逐份实测打开回退（P1-6）；`PlaybackSessionPersistence.saveNow()` 加入冷启动恢复门控并将 `PlaybackStateRecord` 读取提前到异步前（P1-7）；无 `.lrc` 本地曲目不再指向音频本体且支持普通路径读取内嵌歌词、`FileLyricsLoader` 限制文本后缀与 2MB 上限（P1-8）。
- [x] **窗口两条**：`resetPlacementMemory` 按目标 `shape` / 当前屏重算并同步 `model` 与状态机（P1-9）；`applyFloatingOpacity` / `start()` / `.orderFront` 按 `.expanded` 恒不透明分支（P1-10）。
- [x] **播放竞态批**（P2-1…P2-8）：异步 effect 版本守卫、状态迁移即隔离旧会话、取消加载复位、队列稳定身份归一化、补全保留 ID、换列表保留当前项、seek 期间自然结束、单曲循环手动切歌；自然续播不再取消自身任务。`PlaybackReleaseTests` 覆盖可控挂起与真实取消检查。
- [ ] **其余 P2/P3**：优先收口插件导入身份与订阅边界、持久化失败、音频缓存完整性，随后处理其余窗口 / 歌词 / 本地化及旧引擎问题。已知边界见 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)。

---

## 1. 体验质变与高频痛点（第一阶段，已全部完成）

- [x] **不再强制默认悬浮**（HANDOVER 第 206 节）：当时加的是主页「悬浮模式」开关；2026-11-21 改为右上角「普通 / 悬浮 / 沉浸」三档，「切到别的应用时收缩」留在设置 → 形态与自动变形。
- [x] **本地已缓存音频免接口直播（真离线 + 秒开 + 降风控）**（见上方已完成记录与 HANDOVER 第 206 节）。
- [x] **显式离线下载 / 离线歌单管理**（见上方已完成记录与 HANDOVER 第 207 节）。
- [x] **AMLL 逐字 TTML 文件落盘缓存**（已落地 `amll-ttml/` 磁盘缓存与离线直读，见 HANDOVER 第 206 节）。
- [x] **响度自动平衡 + 基础均衡器（EQ）**（已落地，见上方已完成记录与 HANDOVER 第 208 节）
  - 通过 `LoudnessAnalyzer` + `LoudnessCache`（`loudness-v1.json`）在播放准备期测量并持久化响度与峰值安全增益，再经 `MTAudioProcessingTap` + `EqualizerDSP` 5 段实时均衡器与软膝限幅器注入 `HTTPStreamPlayerSession`（当时是 `BilibiliPlayerSession`；保留 `PlaybackEngine.outputGain` 专用于 0...1 淡变与睡眠定时）；设置页「播放 → 音效与均衡」支持随时开关与实时调音。
- [x] **边下边播与无缝切歌（Gapless）**（已落地，见上方已完成记录与 HANDOVER 第 209 节）
  - 通过 `ProgressiveAudioStream`（HTTP `206` 分片首块秒开 + 尾部 probe / 寻址优先 + `.part` 完成原子转为 `.m4a`）与 `Integration/StreamingResourceLoaderBridge.swift`（`AVAssetResourceLoaderDelegate`）替代全首下载阻塞；配合 `PlaybackCoordinator` 下一首后台预热晋升、KVO 零轮询就绪与流式 `.stalled` 缓冲状态上报，消除起播与切歌停顿。

---

## 2. 核心卖点打透：歌词与桌面伴侣（第二阶段）

- [x] **逐字高亮歌词支持多行折行**（已落地，见上方已完成记录与 HANDOVER 第 210 节）：`LyricsDocument` 新增 `LyricWordRun` / `LyricWordHighlight.runs(for:at:)`，[LyricScrollView.swift](../UI/Expanded/LyricScrollView.swift) 以 `AttributedString` 前景分段着色取代 `lineLimit(1)` + `.mask(Rectangle())`，并在 [LyricFieldView.swift](../UI/Expanded/LyricFieldView.swift) 同步支持多行折行。
- [x] **外文歌双语对照歌词开关**（已落地，见上方已完成记录与 HANDOVER 第 210 节）：`AMLLTTMLParser` 与 `LRCParser` 保留 `translation`（经 `TextNormalizer.simplified` 转简体并保留日文原文）与 `romanization`，`LyricScrollLayout` 计入译文高度，`showLyricTranslation`（默认开启，含备份恢复）贯穿主窗口、悬浮歌词、菜单与设置页。
- [x] **歌词手动搜词与持久化绑定**（已落地，见上方已完成记录与 HANDOVER 第 211 节）：在右键「换一版歌词…」Popover 加入歌名/歌手关键词搜索框，统一检索 **AMLL 逐字**（已缓存索引离线可用）与 **LRCLIB**（`/search?q=` 及双字段匹配），经 `LyricBindingStore` 按 `TrackIdentity` 持久化 `.ttml`/`.lrc` 原文并优先于一切自动匹配/CC 字幕加载，支持随时「恢复自动」。
- [x] **全屏 / 沉浸歌词模式**（2026-11-21）：沉浸播放模式，见 [IMMERSIVE_MODE.md](IMMERSIVE_MODE.md)。
- [ ] **悬浮胶囊悬停快捷微控**：悬浮模式下悬停胶囊浮出极简播放/暂停/切歌/收藏按钮，不展开整个大窗口即可操作。
- [ ] **真实全屏隐匿几何兜底**：针对 `AXFullScreen` 真机读回 `false` 的问题，补一条基于 `CGWindowList` 检测前台窗口铺满 `screen.frame` 的兜底判定。
- [ ] **按应用形态规则（白名单 / 黑名单）**：将 `MeetingModePolicy` 思路扩展为按前台应用自定义行为（如写代码缩胶囊、看视频/游戏隐藏、特定设计软件避让）。

---

## 3. 找歌命中率与曲库/歌单完善（第三阶段）

- [ ] **加速歌曲确认并增加可控逃生口**：
  - 优先复用本地已有的 `AMLLLyricsIndex` 做毫秒级快速确认，减少首页/搜索对海外 `lrclib.net` 的串行请求延迟；
  - 给被严格规则筛空的搜索/推荐提供显式可控的「查看未确认结果 / 手动放行」入口，避免冷门歌、Live/翻唱、纯音乐/OST 直接消失；
  - 已加入收藏/歌单的确认记录不再按 30 天强过期失效。
- [ ] **通用收藏/歌单扩展能力与插件生态写回评估**：针对支持 `auth.collections` 的第三方插件与自建服务器（OpenSubsonic），完善外部歌单只读刷新与本地合并策略；
- [x] **媒体流直连兼容扩展（已完成首轮）**：新增音质降级、无后缀音频魔数嗅探、HLS `.m3u8` 直连与 OAuth1/HTML 解析支持；待补更多海外与社区插件格式按需适配。
- [ ] **通用响度测量与 EQ 优化**：针对 HLS（`.m3u8`）远端分片流评估在线流式响度缓存策略；
- 已落地的多音源架构条目详见 [`SOURCE_SPEC.md`](SOURCE_SPEC.md) 与 HANDOVER 第 214–215 节。
- [ ] **首页发现增强**：基于最近播放/收藏生成相似推荐，补充「一键私人漫游/电台」入口，解决首页仅靠排行榜容易偏少或筛空的问题。
- [ ] **歌单与曲库体验完善**：多曲实机拖拽排序验证、按歌手/专辑聚合浏览、歌单内搜索、歌单封面及歌单导入/导出。

---

## 4. 工程拆分、验证收口与可分发准备（第四阶段）

- [ ] **核心大文件拆分**：将 [MorphWindowController.swift](../Morph/MorphWindowController.swift)（2026-11-23 约 2560 行）拆分为窗口动画、投影同步、空间调度协作者，降低后续叠加新功能的竞态风险；同步评估拆分 [SettingsView.swift](../UI/Settings/SettingsView.swift)（2026-11-23 约 2550 行，可按分区拆文件）。
- [ ] **分支收口与基础验证**：
  - [x] 将 `docs/player-ui-acceptance-20261119` 合回 `main`；
  - [x] 本轮执行默认全量 `./Scripts/verify.sh`，再通过 `TEST_RUNNER_SLP_LIVE_TEST=1` / `TEST_RUNNER_SLP_AUDIO_TEST=1` 分组实跑验收记录里列出的联网门控用例与真实音频；均通过，具体用例清单见 [验收记录](evidence/release-2026-11-22.txt)（没有把默认跳过当作验证；记录之外的联网用例不算已验）。2026-11-23 另实跑 `VoiceModelFetchAndMirrorTests` 两条 HuggingFace 实网用例通过；
  - [ ] 真机有声听感与交互走查（淡入淡出、音质热切、断流恢复、隐私/会议遮罩、动态开关联网、右键换版、繁体转简体、三档切换、离线下载播放）；
  - [ ] 清零 `Tests/` 目标内剩余的 100+ 条 Swift 6 `@MainActor` 隔离与未使用变量编译警告；
  - [x] 每次 `verify.sh` 后重跑 `xccov` 更新 [docs/evidence/coverage.txt](evidence/coverage.txt)。
- [ ] **签名、分发与系统专项验收**：
  - [ ] 配置开发者签名与公证（及后续 Sparkle 自动更新），打通 `SpatialLyricsPlayerUITests`、桌面小组件真机（App Group + App Intent）与开机启动（`SMAppService`）；
  - [ ] 补齐真机系统集成走查：媒体键与控制中心联动、会议应用前台自动遮罩实测、多显示器热插拔、VoiceOver 人工读屏、Reduce Motion / Reduce Transparency / 提高对比度切换；
  - [ ] 视觉与交互细修：迷你条/胶囊浅色模式逐项复核、贴边形态极简进度提示、设置窗长分区节奏、`MorphologyTuning` 调试面板、输出设备切换 / AirPlay、队列系统级拖放。
