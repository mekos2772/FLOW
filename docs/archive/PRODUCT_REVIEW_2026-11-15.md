# FLOW 新用户全功能体验评审（2026-11-15）

> **历史文档，不再随代码更新。** 2026-11-15 的新用户评审；文中的"第 N 节"指 [交接日志](HANDOVER_LOG.md)。

> **状态：P0 与 P1 已修完，见 `HANDOVER.md` 第 22 节。**
> 本文件保留原始评审记录作为证据基线；P2/P3 仍未动。

> 方式：清空 `~/Library/Preferences/com.yg.spatiallyrics.plist`、`group.*` 与
> `~/Library/Application Support/SpatialLyricsPlayer`，从零启动 Release 构建，
> 按真实用户路径走完全部功能；用 CGWindowList / AX 树 / 截图 / 系统日志 / 崩溃报告取证。
> 判定基准按大厂消费级音乐 App（Apple Music / Spotify / 网易云）的完成度要求。

构建：`/tmp/slp-release/Build/Products/Release/SpatialLyricsPlayer.app`
系统：macOS 27.3 (26C5035r)，1920×1080 @60Hz

---

## 0. 一句话结论

**这不是"还差打磨"，是"核心链路有几处断点"。**
视觉语言、形态系统、动效这些"作品感"的部分已经站得住；但
**歌词（产品头号卖点）在真实曲目上几乎永远为空**、
**封面永远不显示**、
**收藏/队列两个抽屉永远是空壳**、
**播放中会闪退**、
**播放过一首之后再也回不到首页**。
这五条任意一条在正式发布里都是阻断级缺陷。

---

## 1. P0 — 阻断级（会崩、会丢、会误导）

### P0-1 播放带封面的曲目会闪退（SIGTRAP）

- **现象**：搜索「jay」→ 点第一条 → 约 3 秒后进程消失，无提示。
- **崩溃报告**：`~/Library/Logs/DiagnosticReports/SpatialLyricsPlayer-2026-11-15-062145.ips`
  ```
  EXC_BREAKPOINT / SIGTRAP
  faultingThread 2, queue: */accessQueue
  _dispatch_assert_queue_fail
    ← _swift_task_checkIsolatedSwift
    ← swift_task_isCurrentExecutorWithFlagsImpl
    ← closure #1 in MediaPlayerNowPlayingBridge.update(...)
    ← -[MPMediaItemArtwork jpegDataWithSize:]
    ← _MPToMRNowPlayingInfoDictionary
    ← -[MPNowPlayingInfoCenter _onQueue_pushNowPlayingInfoAndRetry:]
  ```
- **根因**：`Playback/Bridging/MediaPlayerNowPlayingBridge.swift:92`
  ```swift
  lastArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  ```
  `requestHandler` 会被 MediaPlayer 在**它自己的串行队列**上回调；
  闭包捕获了 `@MainActor` 隔离的 `image`（`NSImage`），Swift 6 的执行器断言直接 trap。
  不是"偶发竞态"，是**必然**——只要系统真的去编码这张图。
- **为什么测试没抓到**：`Tests/.../NowPlayingBridgeTests.swift` 三条用例
  （`testPublishesMetadataAndPlaybackState` 等）**都没有传 `artwork:`**，
  于是 `MPMediaItemArtwork` 这条分支从未被测试覆盖。
- **为什么看起来"有时不崩"**：只有 `artwork != nil` 且 `NSImage(data:)` 成功才进这条分支。
  榜单条目大多没有封面 URL，所以是"随机地雷"而不是"每次必崩"——比稳定崩溃更难排查。
- **修法**：handler 必须脱离 actor 隔离。
  ```swift
  // 先把 CGImage / Data 提出来，闭包里只碰 Sendable 值
  let pixels = image.tiffRepresentation   // 或 CGImage
  lastArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
      NSImage(data: pixels ?? Data()) ?? NSImage(size: image.size)
  }
  ```
  并补一条"带 artwork"的单测 + 一条 `nonisolated` 断言测试。

### P0-2 收藏能点亮，但永远进不了收藏列表

- **复现**：播放任意曲目 → 点左侧星标 → 变 `star.fill`（`AXDescription='取消收藏'`）→
  打开「收藏」抽屉 → **仍然是「还没有收藏 / 0 首」**。重开抽屉也一样。
- **根因**：`UI/Expanded/AuxiliaryDrawer.swift:567`
  ```swift
  private var sectionTracks: [Track] {
      let byIdentity = Dictionary(uniqueKeysWithValues: tracks.map { ($0.identity, $0) })
      return favorites.compactMap { byIdentity[$0] }   // byIdentity 永远空
  }
  ```
  `tracks` 来自 `app.tracks.all()`，而 **`TrackRepository.save` 在全工程没有任何调用点**
  （`grep -rn "tracks.save"` 为空）。`TrackRecord` 表永远是空的，
  所以 `favorites` 里存了 identity 也映射不出 `Track`。
- **影响**：收藏 = 纯装饰。这是"用户做完动作却什么都没发生"里最伤人的一种。

### P0-3 队列抽屉 100% 显示「未知曲目」

- 同一根因。`Morph/MorphWindowController.swift:1028` 的 `reloadTrackTitles()` 从空表读标题。
- 实测：队列 23 首，**23 行全是「未知曲目」**，连"正在播放"那行也是。
- 影响：队列功能整体不可用（用户无法分辨任何一行）。

### P0-4 播放过一首之后，再也回不到首页

- **现象**：首页（搜索 + 音乐榜 + 收藏 + 歌单）只在 `model.track == nil` 时出现。
  一旦装载过曲目，右侧歌词栏永久占据；**没有任何"停止/返回首页/浏览"入口**。
- **证据**：`PlaybackEngine.stop()` 存在（`Playback/PlaybackEngine.swift:120`），
  但 `App/ Morph/ UI/ Integration/` 里**没有一个调用点**。
  「清空待播」只清队列，不释放当前曲目。
- **影响**：用户听完一首想换一首 → 只能重启 App。这是致命的流程死胡同。

### P0-5 联网默认值与界面文案直接矛盾

- `DI/SettingsStoring.swift:103`：没写过这个键时 `return true`（**默认联网**）。
- `UI/Settings/SettingsView.swift:257`：「**默认关闭**。开启后才会注册 B 站在线音乐源…」。
- 新用户打开设置，看到开关是**开**的，下面写着"默认关闭"。
  这是隐私承诺层面的自相矛盾，比功能 bug 更损信任。

---

## 2. P1 — 严重体验问题

### P1-1 歌词（头号卖点）在真实曲目上几乎永远为空

- 实测 8 首 B 站推荐 + 3 首搜索结果 + 连续 6 次「下一首」，**无一例外显示「无歌词」**。
- 空状态只给一句「没有找到歌词 / 在歌词区点右键可以换一版」。
- 根因方向：LRCLIB 匹配吃的是 B 站标题原文，而 B 站音乐稿标题大量带
  `【4K60FPS】`、`【Hi-Res无损臻享】`、`《》`、emoji、UP 主名、推广语——
  标题解析（`detail.songTitle`）**只在曲目详情面板里用，没有参与歌词检索**。
- 影响：产品叫 FLOW、卖点是歌词，用户第一次打开 90% 概率看到"没有歌词"。

### P1-2 封面永远不显示（连播放中的大封面也是音符占位）

- 所有截图里左侧 244×244 封面都是灰音符。
- 根因：`Integration/ArtworkStore.swift:56` 的 `.remote` 分支 **直接 `return nil`**，
  而远程封面的下载结果只喂给了 `SystemMediaIntegration.artworkCache`（给控制中心用），
  **从不回写 `ArtworkStore`**；`MorphWindowController.swift:1136` 只读 `ArtworkStore`。
  两条缓存互不相通。
- 影响：一个音乐 App 没有封面 = 没有识别度。用户无法靠视觉认出歌。

### P1-3 搜索要按两次回车

- 复现：点搜索框 → 输入 `yequ` → 回车 → **列表不变、字段不清空、标题也不更新**；
  再按一次回车 → 才出现「搜索「yequ」」和新结果。
- 两次独立复现（`yequ`、`jay`）。第一次回车像是被窗口激活/焦点交接吃掉。
- 相关：`OnlineHomeView.swift:58` 的 `.onSubmit` 是唯一提交入口，
  没有搜索按钮、没有防抖、没有 loading 态在输入框内的反馈。
- 影响：新用户第一反应是"搜索坏了"。

### P1-4 切换任何应用，主界面立刻消失（无设置、无延迟、无撤销）

- 实测：点一下别的 App → 1020×640 的完整播放器在 1 秒内缩成 474×240 的小条并挪到左上角；
  回来才恢复。
- 代码：`MorphWindowController.swift:1451` 收到 `appDeactivated` 就走状态机降级，
  `UI/Settings` 里**没有任何"失焦后是否收缩/多久收缩"的开关**。
- 影响：一边听一边在别处工作的人，永远看不到完整版面。
  这是"桌面伴侣"理念的正确方向，但**默认行为太激进且不可配置**。

### P1-5 空格键播放/暂停无效（设置里承诺了）

- 设置 → 快捷键明写「空格：完整形态里播放/暂停」。
- 实测：完整形态、窗口在前台、点过内容区之后按空格，**播放时长继续走，没有暂停**。
- 代码：`MorphRootView.swift:65` 用 `.onKeyPress(.space)`，依赖 SwiftUI 焦点链；
  点窗口空白处不会把焦点交给这个视图，于是按键直接丢失（无响铃、无提示）。
- 影响：写进设置页的快捷键是坏的，属于"承诺未兑现"。

### P1-6 一个永远点不动的按钮明目张胆挂在歌词区

- `UI/Expanded/ExpandedPlayerView.swift:333`
  ```swift
  FlowIconButton(systemName: "quote.bubble", label: "歌词来源",
                 isEnabled: false, size: 24, symbolSize: 12) {}
  ```
  空实现 + 永久禁用。视觉上它是可点的次级图标，点了什么都不发生，也没有 tooltip 说明。
- 同时右侧「歌词偏移校准」按钮是能用的，两者并排 → 用户会认为"这个也是能用的，只是坏了"。

### P1-7 「歌单」按钮通向一个不存在的分节

- `OnlineHomeView.swift:73`：`chip("歌单") { model.prefersOnlineSection = true; model.auxiliary = .library }`
- 但 `AuxiliaryDrawer.swift:230` 的 `Section` **只有 `.favorites` 一个 case**；
  `onlineContent`（约 190 行的在线面板）**没有任何调用点**，是整块死代码。
- 实测：点「歌单」→ 打开的是「收藏」抽屉 → 显示「还没有收藏」。
- 影响：三个快捷 chip 里有一个是空转。

### P1-8 权限页与真实状态互相打架

- 设置 → 权限：**「当前状态：未授权 · 降级运行」**。
- 但同时：设置 → 形态，「自动避让前台窗口」开关是**开**的；
  悬浮形态也确实在按空间移动。
- 新用户无法判断"避让到底生效没有"。要么在未授权时把开关视觉上标成不可用并说明，
  要么在授权后立刻刷新这一行（现在是两套状态各说各话）。

---

## 3. P2 — 明显不专业 / 打磨缺失

| # | 问题 | 证据 |
|---|---|---|
| P2-1 | **顶栏信息噪音**：「FLOW · 无歌词 · 未登录 B 站 · 自动」四个圆点连成一串，其中「自动」是音质档位名，与「自动变形」撞词 | 截图 `11-expanded-fresh` |
| P2-2 | **首页版面空一半**：空闲态把整块歌词栏换成在线首页，左侧「现在播放」栏还挂着 244×244 空封面 + "还没有播放" + "在右侧搜索或点一首推荐"，但右边已经是榜单了 | 截图 `63-editorial-home` |
| P2-3 | **"在右侧搜索"指向错误**：窄窗口（<880pt）时搜索框在**正下方**，文案仍说"右侧" | `ExpandedPlayerView.swift:128` |
| P2-4 | **弹出菜单用系统蓝**：歌词版式下拉高亮是 `rgb(233,239,248)` 的 macOS 强调蓝，跟纯黑白体系断裂 | 截图 `68-popup-crop` |
| P2-5 | **设置窗是另一套设计**：系统 Form + 灰底 + 蓝色高亮，与主窗口的编辑式黑白版面没有任何共同语言 | 截图 `40-settings-*` 九张 |
| P2-6 | **关于页信息太少**：只有 `0.1.0 (1)`，没有构建时间、没有 commit、没有可复制的诊断入口 | 截图 `40-settings-关于_FLOW` |
| P2-7 | **重开 App 不恢复播放**：闪退/退出后回来一律「还没有播放」，上次的曲目与进度丢失（只有位置记忆恢复） | 实测 |
| P2-8 | **删掉封面后仍显示占位**：`ArtworkStore.image(for:)` 拿不到图时 `model.artwork = nil`，UI 不区分"加载中 / 无封面 / 加载失败" | `MorphWindowController.swift:1136` |
| P2-9 | **「清空待播」语义模糊**：清队列后当前曲目还在播，但队列抽屉变成空 —— 用户不知道歌还在响 | 截图 `91-queue` |
| P2-10 | **抽屉底部常驻「B 站 · 0 首」**：信息量接近零，占了固定高度 | 截图 `90-library-playing` |

---

## 4. P3 — 细节

1. `dormant` 与 `edge` 形态落点不一致（349 vs 357），切换时会有 8pt 的跳动。
2. 形态过渡在远程会话下**看不出明显卡顿**（60Hz 虚拟屏），但也没法证明满帧——建议补一条
   `SLP_DEBUG_FRAME=1` 的 layout 节拍回归。
3. `HairlineSlider` 静止时隐藏滑块，音量/进度都只剩一根 2pt 细线；新用户不知道哪里能拖。
4. 进度条与音量条视觉权重完全相同，左右并列，容易误拖。
5. 专辑/艺人/简介三行的行距和字号层级差距太小（`11-expanded-fresh` 里三条几乎等权）。
6. 简介里直接带出 `BV1ewc9eNENL` 这类 ID（"作者：X@Samess3333 · 素材来自：BV1ewc9eNENL"），
   与"界面不再显示 BV 号"的设计决定冲突。
7. 空歌词区右侧大片空白，没有"换个源/手动搜索歌词/粘贴 LRC"的兜底入口。

---

## 5. 做对了的地方（不要改坏）

- **五形态是同一个窗口的连续变形**：用 `spatiallyrics://morph/<形态>` 逐个验证，
  帧尺寸单调收敛（393×59 → 300×34 → 76×91 → 420×80），没有重影、没有闪白。
- **深浅色都成立**：浅色是 `rgb(245,245,245)` 中性灰，深色是 `rgb(23,23,23)`，
  没有色带、没有接缝；窗口圆角外是真空透明（alpha 0.00）。
- **红点关闭 = 收进菜单栏**，进程存活（这是上一轮修好的，本轮复验通过）。
- **失焦收缩 + 回前台恢复**本身是好的产品直觉，只是缺可配置。
- **菜单栏面板**：268pt 宽、图标 + 一行曲目 + 一行歌词 + 形态切换 + 隐私/歌词/睡眠/账号/设置，
  信息密度和操作可达性都合格。
- **Dock 图标**：`lsregister -f` + `killall Dock` 之后正确显示（之前空白是 LaunchServices 缓存，
  不是图标本身有问题）。

---

## 6. 建议修复顺序

1. **P0-1 崩溃**（`MPMediaItemArtwork` 闭包脱离 MainActor）+ 补带封面的单测。
2. **P0-2 / P0-3 收藏与队列**：在 `PlaybackEngine.play` / 搜索结果装载时
   `await tracks.save(track)`，或让抽屉直接用播放队列里的 `Track` 快照而不查仓库。
3. **P0-4 回首页**：顶栏加「浏览」入口（或让 `xmark` 变成"停止并回首页"），
   并接上已有的 `playback.stop()`。
4. **P1-2 封面**：`SystemMediaIntegration.loadArtwork` 拿到 data 后
   `ArtworkStore.shared.store(data)` 并把结果写回 `Track.artwork`。
5. **P1-1 歌词**：把 `detail.songTitle` / `detail.artist`（已解析）喂给 LRCLIB，
   而不是 B 站原始标题；空歌词时给"手动换源 / 粘贴 LRC"。
6. **P0-5 文案或默认值**二选一，立刻改掉矛盾。
7. **P1-3 回车**：`onSubmit` 外再加一个显式搜索按钮 + 输入即搜防抖，别让唯一入口这么脆。
8. **P1-4 / P1-5**：暴露"失焦后收缩"开关（含"从不"）；空格改成 NSEvent 本地监听，不依赖 SwiftUI 焦点。
9. **P1-6 / P1-7**：删掉死按钮，或接上真实功能；`Section` 补 `.online` 或删掉「歌单」chip。

---

## 7. 附：本次实测清单（是否走通）

| 功能 | 结果 |
|---|---|
| 冷启动 / 首屏 | ✅ 起得来，居中偏上落点，压住别的窗口 |
| 五形态切换（深链） | ✅ 全部到位 |
| 点击胶囊展开 | ✅ |
| 完整形态点击控件 | ✅（点空白不激活应用） |
| 搜索（两次回车） | ⚠️ 第一次被吞 |
| BV 号直搜 | ⏸ 未逐条验 |
| 播放（取流→出声） | ✅ 有声音，进度正常 |
| 播放中系统媒体信息 | ⚠️ 拿到 artwork 时崩溃 |
| 歌词 | ❌ 11 首全空 |
| 封面 | ❌ 全部占位 |
| 收藏 | ❌ 写入但永远显示不出 |
| 队列 | ❌ 全部"未知曲目" |
| 歌单 chip | ❌ 死路 |
| 上一首/下一首 | ✅ |
| 空格暂停 | ❌ |
| 红点 = 收进菜单栏 | ✅ |
| 菜单栏面板 | ✅（未逐项点击） |
| 设置 9 个分页 | ✅ 全部打开并截图 |
| 权限页 | ⚠️ 状态与实际能力矛盾 |
| 开机自启 / 小组件 / 耳机拔出 / 全屏隐藏 / 多屏 | ⏸ 本机无法验证 |
