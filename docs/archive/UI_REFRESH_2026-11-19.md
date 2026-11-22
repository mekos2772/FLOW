# FLOW 主窗口改版与验收记录

> **历史文档，不再随代码更新。** 2026-11-19 主窗口改版的验收记录；当时音源仍是内置 B 站。

日期：2026-11-19

范围：严格歌曲展示、首页与播放页分离、桌面播放器布局、原生最小窗口修复及验收。

## 1. 先说明提交与证据范围

- 本次 Git 更新仅包含本轮 README、交接文档和本记录的定向修改；**不包含相关实现及此前累计代码改动**。
- 文档提交分支：`docs/player-ui-acceptance-20261119`；基于 `2ef438f` 创建，仅本地提交，不推送。
- 以下实现描述、测试数量和原生验收结果针对 **2026-11-19 验收时的累计工作区**，不是仅检出本次文档提交即可重现的代码快照。
- 既有代码、测试目录迁移、旧文档增量和无关未跟踪文件保留在工作区；未把它们混入本轮文档提交。
- 本记录中尚未随代码提交的文件名使用代码格式标注，不制造当前提交树中不存在的相对链接。
- 历史截图、覆盖率和旧发布清单不作为新版全部通过的证明。本轮原生截图在会话中检查，未将其作为新图片文件纳入本次提交。

## 2. 产品方向与已完成内容

### 2.1 界面结构

参考方向已由用户确定：Apple Music 的简洁感，加上 Spotify／QQ 音乐清楚的导航和统一播放栏。不复制广告、会员、社区或密集推荐区块。

```text
┌────────────────────────────────────────────────────┐
│ FLOW              搜索歌名                   窗口工具 │
├───────────┬────────────────────────────────────────┤
│ 首页       │ 页面标题                         刷新    │
│ 搜索结果   │                                        │
│ 收藏       │ 推荐 / 搜索 / 收藏 / 最近 / 歌单         │
│ 最近播放   │ 或：封面与歌词                          │
│ 歌单       │                                        │
│ 正在播放   │                                        │
│ 设置       │                                        │
├───────────┴────────────────────────────────────────┤
│ 当前歌曲      播放控制与进度        音量 / 歌词 / 队列 │
└────────────────────────────────────────────────────┘
```

- 搜索结果入口在提交搜索后出现，正在播放入口和底栏在有当前歌曲时出现。
- 默认窗口 1020×640，侧栏宽 180pt；窄窗口侧栏 156pt。顶部搜索高 38pt、最大宽 380pt。
- 首页、搜索、收藏和最近播放分别保存列表状态；切页不会停止音乐、重置进度或清空队列。
- 搜索词和结果跨页面保留；最近播放按本地资料库记录顺序显示，不按并发确认完成顺序重排。
- 本地收藏不要求 B 站登录。无当前歌曲时不展示大空封面、空时间和无效播放条。
- 页面标题 26pt，歌名 16pt，导航／控件 14pt，次要信息 13pt。去掉重复说明、重复时长与“接下来”预览。
- 底栏合并当前歌曲、播放模式、上一首／播放／下一首、进度、音量、歌词和队列入口。窄窗口隐藏底栏收藏按钮，列表收藏仍可用。
- 队列、快捷设置和歌词校准浮层只覆盖中间内容，不遮挡底部播放控制。
- 主窗口使用中性深浅色和不透明底色，增强按钮正常／悬停／选中／禁用的区分，不改变悬浮形态的默认视觉。

### 2.2 歌曲确认与隐藏规则

- B 站仍提供音频，LRCLIB 用于歌曲元数据确认及歌词；没有更换音源或使用音频指纹。
- 歌名规范化后精确匹配；有可靠歌手信息时严格匹配歌手，UP 主不能作为歌手回退。
- 时长与 Live／Remix／现场／伴奏等版本信息参与匹配；BGM 只作为线索，不单独放行。
- 搜索词匹配确认后的歌名。规范歌名、真实歌手、封面、时长与播放控制可见；未确认条目、UP 主、原始视频标题和简介不可见。
- 搜索、推荐、收藏、历史、歌单、队列及生产播放入口接入确认；旧收藏和歌单中的未确认项只隐藏，不删除。
- 确认缓存、并发限制、相同请求合并、取消和代次保护用于减少重复请求并防止迟到响应覆盖当前页面。
- **覆盖率限制**：严格推荐可能为空，搜索也可能漏掉可播放歌曲。真实“夜曲”查询至少确认过一首，不代表其他歌名或所有版本均可用。元数据吻合不能保证音频内容百分之百一致。

### 2.3 歌单

- 主窗口嵌入歌单内容，原账户设置弹窗继续复用同一内容组件。
- 支持新建、选择、单首播放、播放全部、加入当前曲目、移除与排序。
- 空白名称不能创建。删除必须确认，取消不会删除；删除歌单不删除当前歌曲或收藏。
- 隐藏条目存在时，移除和排序仍映射到原始条目索引，不误操作相邻条目。
- 本轮没有扩展为完整批量管理、下载管理或完整歌单重命名流程。

### 2.4 原生最小窗口修复

实机发现，单独声明几何 `minimumSize` 不会限制原生拖窗；只设置 `panel.minSize` 后，属性单测虽通过，实际仍能缩到 734×427 等小于目标的尺寸，挤压歌单列表。

最终处理：

1. 完整形态设置 `panel.minSize` 为 780×480。
2. `MorphWindowController.windowWillResize` 对完整形态的实际缩放请求钳制到该下限。
3. 悬浮形态清除 `minSize`，代理不限制悬浮尺寸，避免破坏连续收缩。
4. 高度小于 560pt 时，侧栏行高 32pt、行间距 2pt、垂直边距 4pt；内容垂直边距 12pt，歌单间距 12pt。
5. 最终真实鼠标拖窗停在 **780×480**，歌单行、全部已出现的导航入口和底栏可见。

没有借此修改形态动画 watchdog 或其他独立状态机问题。

## 3. 实现与回归测试位置

下列路径相对工程根；部分文件仍未随代码提交。

| 文件或目录 | 本轮职责 |
|---|---|
| `UI/Expanded/ExpandedPlayerView.swift` | 主窗口分区、矮窗口间距、浮层边界、播放页宽窄布局 |
| `UI/Expanded/PlayerNavigation.swift` | 侧栏、顶部搜索、最近搜索弹层 |
| `UI/Expanded/OnlineHomeState.swift` | 分页列表状态、搜索保留、本地收藏／历史加载、取消与代次保护 |
| `UI/Expanded/OnlineHomeView.swift`、`SongRow.swift` | 共享歌曲列表和歌曲行 |
| `UI/Expanded/TransportBand.swift` | 统一底栏、seek、音量／静音、播放模式、歌词和队列入口 |
| `UI/Bilibili/PlaylistPageState.swift`、`PlaylistView.swift` | 共享歌单状态与内容、删除确认、原始索引映射 |
| `Morph/MorphPresentationModel.swift` | 浏览与播放页切换，不停止音频会话 |
| `Morph/MorphWindowController.swift` | 原生最小尺寸与缩放代理 |
| `DesignSystem/FlowComponents.swift`、`Tokens.swift`、`HairlineSlider.swift` | 字号、主窗口按钮对比、真实禁用、滑杆无障碍编辑回调 |
| `Resources/Localizable.xcstrings` | 新导航、歌单、播放操作与空态的中英词条 |
| `Tests/SpatialLyricsPlayerTests/UI/` | 导航状态、歌单操作、长标题、深浅色、最小窗口与底部进度渲染 |
| `Tests/SpatialLyricsPlayerTests/Morph/MorphWindowContractTests.swift` | 最小尺寸仅限制完整形态的窗口契约 |

测试修订没有通过恢复冗余小字来迎合旧截图：空队列抽出真实复用的 `QueueEmptyState` 进行组件渲染；首页探针检查标题与空态区域，不再用旧完整首页的整屏“墨水比例”衡量内容子视图。

`ImageRenderer` 对原生 TextField、ProgressView 和 ScrollView 有局限，出现占位或离屏状态不代表实际窗口如此。尺寸断言、非空像素和单测均不能代替原生验收。

## 4. 最终自动化验证

以下是最后一次代码验收的结果，本次文档整理没有重新运行完整构建，也没有把旧日志当作新一轮执行。

| 验证项 | 最终结果 |
|---|---|
| Debug 单元测试及测试构建 | `Executed 1211 tests, with 21 tests skipped and 0 failures`；`TEST SUCCEEDED` |
| Release 构建 | `BUILD SUCCEEDED` |
| 架构检查 | `architecture-lint: OK` |
| 死代码扫描 | `dead-code-scan: OK`，没有零引用的类型 |
| 代码验收时的差异空白检查 | `git diff --check` 通过 |

21 条跳过包含联网开关、可选音频环境与外部样本等条件。本轮没有逐项重新分类，因此不编造各类数量，也不把跳过算作已验证通过。

### 4.1 复现命令

从工程根执行；这组命令要求拥有验收时的累计代码，文档提交本身不提供该代码快照。

```bash
xcodebuild test \
  -workspace SpatialLyricsPlayer.xcworkspace \
  -scheme SpatialLyricsPlayer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/flow-code-review.AIVjwH/DerivedData \
  -parallel-testing-enabled NO \
  -only-testing:SpatialLyricsPlayerTests \
  CODE_SIGNING_ALLOWED=NO \
  > /tmp/flow-ui-accepted-tests.log 2>&1

xcodebuild build \
  -workspace SpatialLyricsPlayer.xcworkspace \
  -scheme SpatialLyricsPlayer \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/flow-code-review.AIVjwH/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  > /tmp/flow-ui-accepted-release.log 2>&1

bash Scripts/architecture-lint.sh
python3 -I Scripts/dead-code-scan.py
git diff --check
```

### 4.2 日志与警告

- `/tmp/flow-ui-accepted-tests.log`：最终总数在 3657／3659 行，`TEST SUCCEEDED` 在 3667 行。
- `/tmp/flow-ui-accepted-release.log`：`BUILD SUCCEEDED` 在 143 行。
- 测试日志含 QoS 优先级反转警告，以及离屏渲染测试访问 FocusState 的警告；**不宣称全程零警告**。
- 最后一次 Release 增量日志未检出 warning，不等于完成过 clean 全构建的零警告审计。
- 日志为本机临时文件，可能被系统清理；本次提交不包含完整日志或 xcresult。
- 本轮未重测覆盖率，未运行 `check-doc-numbers.sh`；它依赖另一组历史日志和报告，不以它替代本记录中的证据。

早期适配新布局时曾出现渲染阈值、旧空态文案契约和漏翻译失败，均在最后一轮前修正。此前失败记录不是最终验收结果，也未被隐瞒为“一次全绿”。

## 5. 原生交互验收

### 5.1 隔离与安全

- 使用独立数据目录 `/tmp/flow-ui-light.twJZ7v`、`SLP_DEBUG_MUTE=1`、内存凭证；深色阶段使用 `SLP_DEBUG_APPEARANCE=dark`，初始主窗口使用 `SLP_DEBUG_MORPH=expanded`。
- 不读取真实登录凭证，不使用真实账号，不修改真实收藏或歌单。
- 音量调节测试在暂停状态进行，恢复播放前重新确认静音。
- 测试歌单为“UI验收歌单”，最后通过确认删除；隔离收藏保留。所有本轮验收进程均已退出。
- 最初桌面处于登录窗口，深色及最小窗口验收曾受阻并明确报告；桌面恢复后才继续完成以下操作。

### 5.2 已实际操作并观察结果

| 场景 | 观察结果 |
|---|---|
| 浅色与深色主窗口 | 导航、内容和底栏可见；空首页不再占用大空封面与无效播放条 |
| 搜索与切页 | 实际键盘输入并提交；切收藏后返回搜索结果，查询与结果保留 |
| 最近搜索 | 弹层出现，点击历史词可重新提交 |
| 本地收藏与最近播放 | 可展示确认歌曲，不依赖真实在线登录；播放记录进入最近播放 |
| 浏览与播放页分离 | 播放／暂停状态下切回浏览页不停止或重置当前歌曲 |
| 歌单操作 | 新建、加入当前曲目、单首播放、播放全部与移除可用 |
| 歌单删除 | 取消不删；确认后删除歌单，当前歌曲和收藏仍保留 |
| 播放进度 | 鼠标拖动进度后 seek 生效，真实流进度与歌词可观察 |
| 音量／静音 | 暂停时鼠标调节音量，随后重新静音 |
| 播放模式 | 随机、单曲循环和列表循环切换可观察 |
| 队列浮层 | 打开后不遮挡底部控制 |
| 原生缩窗 | 最终拖动受限于 780×480；歌单行、7 个已出现的导航入口和底栏可见 |

### 5.3 工具与验收边界

- 使用 Computer Use 对实际 macOS 窗口操作，不是正式 XCUITest 套件执行结果。
- 某些 SwiftUI 控件的 AX `setValue` 显示值变化但没有驱动真实绑定；因此搜索／歌单名称改用实际键盘输入，进度／音量改用鼠标拖动并再次观察。
- 滑杆已接无障碍编辑回调，但不能据此宣称 VoiceOver 已通过。自动失焦收缩导致的失效控件引用均重新观察后操作，未把工具返回成功直接当作业务成功。
- 真实音源播放始终静音；已验收取流链路、可观察进度、歌词与交互，不代表音质、听感、可听连续性或淡入淡出听感通过。
- 多首歌单拖拽排序主要由单测覆盖，本轮没有完成多曲实机拖拽演示。

## 6. 尚未解决的独立问题（2026-11-20 已全部修复闭环）

以下四项历史遗留问题与 2026-11-20 深度审查发现的其余 P0/P1/P2 问题，已于 **2026-11-20** 在工作区实现修复并合入 `ReviewRegressionTests`（16 条单元测试全绿；全量单测 `1218` 条执行、`19` 跳过、`0` 失败，Release 构建 `0` 警告）：

| 问题 | 修复后现状 |
|---|---|
| B 站恢复重试强制 `autoplay: true` | **已修**：沿用 `PlaybackContext.pendingAutoplay` 保留暂停恢复语义 |
| 首次恢复失败后丢失原播放断点 | **已修**：`BiliRecoveryDriver` 记录 `resumePosition` 跨多次重装不归零，且支持 `.ready`/`.playing` 跳回 |
| 形态动画 watchdog 缺少 generation／取消归属 | **已修**：`watchdogGeneration` 在 `animateFrame` 延迟收尾中校验，`WindowFrameAnimator.settle()` 及时销毁 `CADisplayLink` |
| 退出时未等待队列 Track 的异步持久化 | **已修**：`PlaybackSessionPersistence` 改用有序 `pendingSaveGates` 按批放行并限时等待 |

> 其余 2026-11-20 一并修复项（默认 `LyricScrollView` 隐私遮罩、「允许联网」双向门控、菜单栏/小组件严格隐藏规则、搜索再编辑、`LyricVariantMenu` Popover、错误/模型本地化、死代码与 plist 清理、全链路中文歌词转简体）见 `docs/HANDOVER.md` 第 205 节。

其他功能边界：找歌覆盖率仍受严格确认影响；歌单管理尚非完整产品；完整本地导入、下载／离线、均衡器、无缝播放及歌手／专辑浏览不应被描述为全部具备。多屏热插拔、完整 VoiceOver、正式 XCUITest 和听感仍需专项验收。

## 7. 后续交接

1. 累计实现、测试目录整理、代码审查修复与简体歌词归一现均已纳入工作区等待统一提交。
2. 补充正式 XCUITest、VoiceOver、听感和多曲歌单实机排序验收，再更新覆盖率报告。
3. 保持歌曲确认、音源、音频内核和歌词匹配边界，不为提高可见条目数量而悄悄放宽过滤。
