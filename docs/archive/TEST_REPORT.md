# 测试报告

> **历史文档，不再随代码更新。** 早期测试分布与逐轮增减记录（229 → 374 条那一段）；当前测试基线见 [上线清单](../RELEASE_CHECKLIST.md)。

对应规格「第二十四部分 · 交付物 #16」。所有数字来自本机实际执行，非估算。

## 环境

```
  ProductName:		macOS
  ProductVersion:		27.3
  BuildVersion:		26C5035r
  Xcode 27.2
  Build version 27B52
  Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)
```

## 单元测试（已实际运行）

命令：

```bash
xcodebuild test -workspace SpatialLyricsPlayer.xcworkspace \\
  -scheme SpatialLyricsPlayer -configuration Debug \\
  -destination 'platform=macOS,arch=arm64' \\
  -derivedDataPath /tmp/slp-dd \\
  -only-testing:SpatialLyricsPlayerTests CODE_SIGNING_ALLOWED=NO
```

结果：**Executed 281 tests, with 0 failures，TEST SUCCEEDED**（229 → 281 为本轮区间新增）。

### 用例分布

| 用例数 | 测试文件 |
|---:|---|
| 30 | `SpatialSolverTests.swift` |
| 13 | `SpatialGeometryTests.swift` |
| 13 | `PlaybackStateMachineTests.swift` |
| 12 | `PlaybackQueueTests.swift` |
| 11 | `PlaybackEngineTests.swift` |
| 11 | `LRCParserTests.swift` |
| 8 | `LyricEngineTests.swift` |
| 7 | `Phase6Tests.swift` |
| 7 | `PersistenceSchemaTests.swift` |
| 7 | `FloatingPlacementTests.swift` |
| 7 | `FloatingPanelContractTests.swift` |
| 6 | `WidgetSnapshotTests.swift` |
| 6 | `MockSourceTests.swift` |
| 6 | `MiniModePersistenceTests.swift` |
| 6 | `LyricTimelineTests.swift` |
| 5 | `DeepLinkRouterTests.swift` |
| 5 | `ArchitectureBoundaryTests.swift` |
| 4 | `LyricsShapeCatalogTests.swift` |
| 4 | `LyricsOpacityTests.swift` |
| 4 | `LocalFilePlaybackTests.swift` |
| 4 | `LibraryStoreTests.swift` |
| 4 | `InMemoryPlacementStoreTests.swift` |
| 4 | `InMemoryLyricsOffsetStoreTests.swift` |
| 4 | `ErrorMappingTests.swift` |
| 4 | `EdgeSnapTests.swift` |
| 4 | `ArtworkStoreTests.swift` |
| 4 | `AppContainerTests.swift` |
| 3 | `VolumeTests.swift` |
| 3 | `TrackIdentityTests.swift` |
| 3 | `RedactingLogTests.swift` |
| 3 | `PlaybackSessionPersistenceTests.swift` |
| 3 | `NowPlayingBridgeTests.swift` |
| 3 | `MiniOnTopWindowLevelTests.swift` |
| 3 | `LyricsShapeCycleTests.swift` |
| 3 | `LocalizationTests.swift` |
| 3 | `CorruptionRecoveryTests.swift` |
| 3 | `AppearanceDefaultsTests.swift` |
| 3 | `AccessibilityContractTests.swift` |
| 2 | `SourceSubstitutionTests.swift` |
| **281** | **合计** |

## 分层检查（已实际运行）

```
$ ./Scripts/architecture-lint.sh
architecture-lint: OK
```

## 构建（已实际运行）

```
$ xcodebuild build -workspace ... -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
** BUILD SUCCEEDED **
```

## UI 测试（未运行）

**覆盖率 0，不声称通过。**

原因：本机 `security find-identity -v -p codesigning` 返回 `0 valid identities found`，
XCUITest runner 启动即被系统杀掉：

```
SpatialLyricsPlayerUITests-Runner (81618) encountered an error
(Test crashed with signal kill before establishing connection.)
```

规格 20.3 要求的 11 个场景（首次启动 / 导入本地音乐 / 播放暂停 / 切歌 / 队列排序 /
歌词校准 / 四形态切换 / 穿透与交互切换 / 多显示器逻辑 / 设置修改 / 隐私模式）
全部未执行。

## 运行时实测（非单元测试，独立证据）

| 行为 | 观测值 | 手段 |
|---|---|---|
| 悬浮不透明度 0.35 | `alpha=0.34999999` | 改设置后读 `panel.alphaValue` |
| 悬浮不透明度 0.8 | `alpha=0.80000001` | 同上 |
| 悬浮不透明度 0.1 | `alpha=0.30000001` | 越界钳制生效 |
| 迷你置顶开 | `layer=3` | 窗口列表 |
| 迷你置顶关 | `layer=0` | 同上 |
| 遮挡避让 | 面板 `930,1023 → 1130,1027` | 移动 Calculator 压住面板 |
| 真实屏幕 | `frame=(0,0,2048,1152)` `visibleFrame=(0,79,2048,1043)` | NSScreen |

## 性能（部分未测）

| 指标 | 目标 | 实测 | 状态 |
|---|---|---|---|
| 冷启动 | < 2s | 2.67s（Debug） | **未达标** |
| 热启动 | — | 0.76–0.77s（Debug） | 记录 |
| 空闲 CPU | ≈0 | 未长时间采样 | 未测 |
| 重排 P95 | ≤200ms | 未测量 | 未测 |
| 1 万首曲目 | 无明显卡顿 | 未构造该规模 | 未测 |
| 长时间播放内存 | 无持续增长 | 未做 soak test | 未测 |

## 结论

281 条单元测试、分层检查、Debug 构建三项已实际执行并通过。
UI 测试与性能项未执行，按规格要求标为「未验证」，不标为通过。
完整缺口清单见 [KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md)。


### 本地化完整性审计（Round 75）

用脚本比对「界面代码里的中文字面量」与 `Localizable.xcstrings` 的键：

```python
pat = re.compile(r'(?:Text|Button|Toggle|Picker|Label)\("([^"\\]*[\u4e00-\u9fff][^"\\]*)"')
# 扫描 UI/ MenuBar/ Overlay/ 下所有 .swift，收集不在字符串表里的键
```

结果：修复前 3 条缺失，修复后 0 条。补入的译文：

| 键 | en |
|---|---|
| 恢复默认布局 | Reset layout |
| 清除记住的位置与形态，并回到默认形态。 | Forgets the saved position and shape, then returns to the default shape. |
| 数据库曾损坏，已隔离并重建空库 | The database was corrupted; it has been quarantined and a new empty store was created. |

字符串表从 103 条增至 106 条；`LocalizationTests` 增加了对前两条的断言，
避免以后新增控件时又漏进表（原测试只要求总数 > 60，管不住新增）。


### P1 睡眠定时（Round 77）

新增两组测试，共 8 条：

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `SleepTimerTests` | 6 | 剩余时间、未到点不触发、到期只触发一次、取消、重设覆盖、零时长视为关闭 |
| `SleepTimerDriverTests` | 2 | 到点**真的调用 pause**（断言 `paused(user)`）、取消后不再暂停 |

关键设计：`SleepTimer` 只做时刻判定，等待交给 `PlaybackClock.sleep`。
因此测试用假时钟瞬间"过完"30 分钟——不需要真的等，也没有用 `setTimeout` 假装播放。


### P1 淡入淡出（Round 80）

`FadeRampTests` 5 条 + `FadeDriverTests` 3 条：

| 断言 | 咬住的行为 |
|---|---|
| 首尾等于端点 | 淡变必须真的到达目标音量，而不是差一点点 |
| 单调不回升 | 淡出途中音量不能反弹（会听见"抖"） |
| 越界夹紧 | 输入 1.5 / -0.5 时曲线内部就夹到 0...1 |
| steps=0 仍返回首尾 | 退化路径不会返回空数组 |
| 步数向上取整且不为 0 | 610ms / 60ms 必须得 11 段，不是 10 |
| `fadeOut` 后 volume == 0 | 真的写进播放器，不只是算了个数组 |
| `fadeIn(to:)` 后 volume == 0.7 | 同上 |
| `cancel()` 还原 0.9 | 取消淡出不能把用户音量永久压在 0 |

写这段时被浮点咬了一次：`0.8 + (0.2-0.8)*1.0` 得到 0.19999999，断言失败。
修法是首尾索引直接返回端点值，而不是放宽断言——放宽了就测不出"没到端点"这种真 bug。


### 淡出接入睡眠定时（Round 81）

`SleepTimerDriver` 增加可注入的 `FadeDriver`：到点先 `fadeOut(over: 600ms)` 再 `pause()`。
新测试 `testFadeOutRunsBeforePause` 同时断言两件事——音量为 0 **且** 状态是 `paused(user)`；
只断言暂停会漏掉"淡出没跑"的退化实现。


### 淡出时长可配置（Round 82）

新增设置键 `settings.fadeOutMillis`（0...3000，默认 600），贯通四层：
`SettingsStoring`（协议 + UserDefaults + InMemory）→ `AppearanceSettings` → `SleepTimerDriver.fadeOutDuration` → 设置页 Picker。

新增测试 `testZeroFadeDurationSkipsFadeAndPausesImmediately`：
选「不淡出」时**音量必须仍是 0.8**，但状态必须是 `paused(user)`。
这条防止把 `duration = 0` 实现成"跳过一次也不暂停"。


### 诊断信息导出（Round 83）

`DiagnosticsReportTests` 4 条：字段齐全、用户目录被抹掉、长令牌折叠成前 4 位、末尾只有一个换行。

`DiagnosticsReport.render` 生成的内容最后统一过 `RedactingLog.sanitize`——
**不是"我们保证不写敏感信息"，而是写完之后再抹一遍**，这样即使将来往报告里加了新字段也不会漏。

写时被 Swift 6 拦了一次：`static var timestampProvider` 被判为
`nonisolated global shared mutable state`。改成 `@MainActor` 隔离后通过。


### 本地导入服务抽取 + Dock 拖放（Round 84）

`LocalImportServiceTests` 2 条：
1. 三个文件里两个能解析 → 返回 2 首导入 + 1 个带文件名的拒绝，且成功项都落库；
2. 缺封面的曲目会被补上 `ArtworkReference`，引用指向刚存下的那条。

抽取的理由：Dock 拖放走 `application(_:open:)`，和工具栏「导入音频」必须走同一段逻辑，
否则"工具栏导入会补封面、Dock 拖进来不会"这种分叉迟早出现。

被 Swift 6 拦了一次：`ArtworkStore.shared` 是 `@MainActor`，
把存图闭包标成 `@Sendable` 就编译不过。改成普通闭包（调用点本身就在 MainActor 上）。


### 设置备份 / 恢复（Round 85）

`SettingsBackupTests` 6 条：

| 断言 | 咬住的行为 |
|---|---|
| 快照 JSON 往返相等 | 编码解码不丢字段 |
| 快照反映实时设置 | 不是读默认值而是读当前 store |
| 拒绝未来版本 | 来自更新版本的文件明确报错，不猜默认值 |
| 拒绝非法 JSON | 报 `.malformed` 而不是崩溃 |
| 恢复时夹紧越界值 | 手改过的备份（字号 999 / 透明度 5 / 淡出 -30）不会写进设置 |
| 未知形态保留原值 | `"hexagon"` 不会被写成脏数据 |

这轮踩到一个自造的坑：用 `if 'exportSettingsBackup' not in s` 做守卫，
但按钮文本里已经含这个字符串，守卫恒为假——方法没插进去，编译报
`cannot find 'exportSettingsBackup' in scope`。守卫应该判断**函数定义**而不是任意出现。


### 会议模式（Round 86）

`MeetingModePolicyTests` 3 条 + `PrivacyStateMeetingTests` 3 条：

| 断言 | 咬住的行为 |
|---|---|
| 功能关闭时前台是会议应用也不遮 | 开关优先于环境 |
| 只遮名单内的应用 | Safari 在前台不触发 |
| 前台未知（nil / 空串）不遮 | 拿不到 bundle id 时保守处理 |
| 自动遮罩不改用户开关 | `isEnabled` 保持 false，`isMasking` 为 true |
| 离开会议应用自动解除 | 环境事实可回退 |
| 手动隐私 + 任何前台仍遮 | 两个条件取或 |

关键设计：`isEnabled`（用户意愿）与 `isMaskedByMeetingApp`（环境事实）**分开存**，
`isMasking` 取二者之或。混成一个布尔值后，"关掉手动隐私"会把自动遮罩一起关掉。


### 设置项与悬浮层的接线审计（Round 88）

用 `grep -rn "appearance\.X" Overlay/` 逐个核对设置页的每个开关是否真的被悬浮层消费：

| 设置项 | 修复前 | 修复后 |
|---|---|---|
| `lyricFontSize` | 0 处引用（Round 87 修） | 已接线 |
| `lyricLineSpacing` | **0 处引用** | 已接线（模型 + 歌词板/双行 + 实时同步） |
| `autoAvoidEnabled` | **0 处引用**（只写 UserDefaults） | 已接线（启动读入 + 立即重新求解） |
| `floatingOpacity` | 3 处 | 正常 |
| `defaultShape` | 3 处 | 正常（记忆优先，Round 72 已知） |

三次都属同一模式：**设置被持久化，但没有任何运行时代码读它**。
测试只覆盖纯逻辑，覆盖不到"UI 真的读了那个值"，所以这类缺陷只能靠 grep 审计发现。


### 设置项消费方全量审计（Round 89）

脚本把 `SettingsStoring` 的 13 个属性逐个拿到全仓库（排除测试与存储实现本身）数消费方：

```python
for name in props:
    hits = [f for f in files if re.search(r'\b'+name+r'\b', f.read_text()) and not is_test_or_store(f)]
```

结果：**没有完全没人读的设置项**（Round 88 修完那三个之后）。但发现两处**弱消费**：

| 项 | 情况 |
|---|---|
| `defaultSourceID` | 只在 `AppConfiguration` 里，而那里用的是静态 `.mock`，运行时从未读设置 → 死配置 |
| `isPrivacyMode` | 只在 `SettingsBackup` 与 `PrivacyState` 里，符合预期 |

顺带发现设置页写着「英文界面尚未完成本地化」，而实际 `en.lproj` 有全部 137 条译文、测试逐条断言过——
这句是陈旧文案，已改为「跟随系统」并说明"没有应用内语言切换"。


### 耳机拔出暂停（Round 90）

`AudioRoutePolicyTests` 5 条：

| 断言 | 咬住的行为 |
|---|---|
| 耳机 → 内置扬声器/未知 | 暂停 |
| 首次读取（previous == nil） | **不**暂停（没有"之前"可比，不能误判） |
| 扬声器 → 耳机 | 不暂停（插上耳机不该中断） |
| 耳机 → 耳机 | 不暂停（有线切蓝牙仍是耳机） |
| 关闭开关 | 永不暂停 |

分类只认内置耳机口（数据源四字符码 `hdpn`）与蓝牙；USB 声卡与 AirPlay 归 `.other`，
**判定不了就不暂停**——误暂停比漏暂停更打扰人。


### 封面取色（Round 97，UI 重构起点）

`ArtworkPaletteTests` 4 条：HSB 往返不丢通道、降饱和/夹亮度后色相不变且不超上限、
纯色图面积平均色准确（±0.02）、无封面返回 nil。

顺手修掉一个工程陷阱：`project.pbxproj` 用 `PBXFileSystemSynchronizedRootGroup` 按目录同步，
**新建的 `DesignSystem/` 不在列表里，文件根本不会被编译**——而 `xcodebuild build` 仍报成功，
因为没有任何代码引用它。补上同步组条目后测试才看见符号。这类"静默不参与编译"比编译错误更危险。

---

## 形态重构轮（本轮）

### 新增

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `MorphologyStateMachineTests` | 17 | 用户意图优先、锁定、失焦稳定后才收缩、免打扰期、冷却、动画打断、全屏/睡眠、抽屉浏览期禁止收缩、冷启动不收缩 |
| `MorphologyEngineTests` | 19 | 空桌面只放宽一档、永不推荐完整播放器、单/多窗口遮挡降级、窄缝降贴边、全屏无解转隐匿、当前仍合适不动；几何：展开锚点、缩小入区、折叠保顶左、避障换位、贴边、把手、最近边确定性；过渡计划时长与淡出迁移 |
| `ObstacleFilterTests`（同文件内） | 3 | 桌面不是障碍物（`AXDesktop`）、标准窗口是、非窗口角色忽略 |
| `MorphWindowContractTests` | 11 | 完整形态可成为 key、悬浮形态永不成为 key/main、Space 行为、单窗口承载五形态、穿透、可见性、安全区、复位清记忆、形态锁定 |
| `MorphControllerBehaviorTests` | 10 | 深链解析与落地、`openPlayer` 展开、显式形态抑制激活展开、隐匿两种策略、策略持久化、歌词排布影响高度、排布与形态独立、形态循环顺序 |
| `MorphTestSupport`（Support） | — | 零时长调参 + 统一构造，避免测试被 0.4s 缓动挡住 |

合计新增 60 条，总数 324。

补充：`testNonactivatingOnlyAppliesToFloatingMorphologies` 是本轮最后一条新增——
它锁定的正是"完整形态里按钮点不动"的根因（`.nonactivatingPanel` 让应用永不激活，
macOS 的 Button 在非激活应用里不响应；加上 `ResizeGrip` 撑满 overlay 吃掉事件，两者叠加）。

### 删除（附理由）

| 文件 | 条数 | 理由 |
|---|---:|---|
| `FloatingPanelContractTests` | 8 | 被 `MorphWindowContractTests` 取代：契约从"永不成为 key 的悬浮面板"变成"完整形态可成为 key、悬浮形态永不"。断言更严格，不是放宽 |
| `MiniModePersistenceTests` | 6 | "迷你模式"这个布尔被形态系统取代（`compact` 是一个形态，不是外观开关），保留会造成死配置 |
| `MiniOnTopWindowLevelTests` | 3 | 同上：置顶不再由迷你模式开关控制，而是由形态决定层级；等价契约已在 `MorphWindowContractTests` 里 |

### 改写

- `AccessibilityContractTests`：面板从"整体伪装成一个静态文本元素"改成"容器元素 + 穿透态对 VoiceOver 隐藏"，
  因为窗口里现在有真实控件，再把整窗当静态文本会让控件在 VoiceOver 里消失。
- `DeepLinkRouterTests` / `FloatingPlacementTests`：构造从 `FloatingPanelController` 迁到 `MorphWindowController`。

### 新发现并修复的缺陷（都被测试或实测抓过）

1. Finder 桌面被当作全屏障碍物 → 一切走就隐匿（`WindowGeometryReader.isObstacleCandidate`）。
2. 进度条把"秒"当 0…1 用 → 永远显示 100%（`range: 0...duration`）。
3. `application(_:open:)` 里多写了一次 `expand()` → 深链切胶囊后立刻被拉回完整形态。
4. 过渡结束才 `orderOut` 的收尾动作没被执行 → 隐匿形态窗口留在屏幕上。

---

## 第二轮（设置与交互打磨）

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `AutoMorphSettingTests` | 3 | 关闭自动变形后空间决策被拒（`autoMorphDisabled`）、打开后仍会收缩、关闭时用户操作仍然生效 |

总数 327。

同时修复了两个只在真实交互里才暴露的缺陷（详见 `RUNTIME_EVIDENCE.md` 8.9）：
拖拽缩放必崩（`NSHostingView` 抢窗口尺寸）、缩放位移非线性（手柄随窗口移动）。

---

## 第三轮（错误可解释性）

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `PlaybackErrorPresentationTests` | 4 | 每个错误都有标题与解释；格式不支持只给跳过不给重试；文件缺失两者都给；联网关闭时手动可重试 |
| `MorphRestoreConsistencyTests` | 2 | 冷启动恢复形态必须同时同步状态机（否则点胶囊被判 `redundant`、点了没反应）；锁定状态随形态一起恢复 |

总数 333。

---

## 第五轮（全局快捷键）

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `HotkeyBookkeepingTests` | 2 | 连续注册多个 action 不会互相踢掉；注销其中一个只少一个 |

总数 335。Carbon 的 `RegisterEventHotKey` 在测试宿主里可能整体不可用，
两条测试在这种情况下 `XCTSkip` 而不是假绿；实机核对靠设置里的"已注册 3 / 3"。

---

## 第七轮（自适应引擎专项）

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `MorphologyRelocationTests` | 3 | 被压住 → 必须要求移动（`currentStillFits=false`）；没被压住 → 不动；轻微遮挡（低于阈值）→ 不动 |

总数 338。实机验收见 `ADAPTIVE_ENGINE.md` 第三节。

---

## 第十轮（移动连续性与遮挡并集）

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `CoverageTests` | 4 | 重叠障碍物按并集算不翻倍；部分重叠取并；界外为 0；全覆盖为 1 |

总数 343。移动的远近淡出迁移由既有的 `MorphTransitionPlanTests` 覆盖，本轮只是把移动也接上同一条路径。

---

## 连续布局重构

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `ContinuousPlacementSolverTests` | 6 | 中部自由位置（非角点）、多窗口不规则空间、当前位置合法时不动、缝隙只够胶囊时不换迷你、落点随起点连续变化、无解返回 nil |

总数 352。

---

## 连续布局：无遮挡优先

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `ClearancePriorityTests` | 2 | 干净空间在远处时也必须去（不得就近压扁）；当前已无遮挡则不动 |
| `PlacementTradeoffTests` | 2 | 原地缩小胜过横跨屏幕；同尺寸时倾向保持形态 |

总数 356。

---

## 连续布局：自由矩形与多屏

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `FreeSpaceMaximalityTests` | 4 | 极大性剪枝、空区不丢失、无障碍全景、重叠障碍 |
| `MultiDisplayGeometryTests` | 5 | 副屏负坐标、上方副屏、刘海只扣一次、副屏内求解 |
| `VisibleWindowScannerTests` | 3 | 排除自身窗口、过滤过小窗口、AppKit 坐标 |

总数 369。

---

## 连续布局：权限降级

| 文件 | 条数 | 覆盖 |
|---|---:|---|
| `PermissionDegradationTests` | 5 | 未授权丢弃 AX、不得假装识别外部窗口、未授权时扫描仍工作 |

总数 374。

---

## 后续轮次与当前全量基线（2026-11-20）

> 注：以上内容保留为早期第 229 → 374 条阶段测试增量日志。此后 UI 刷新、第一阶段全部 6 项体验升级、第二阶段 1–3 项，以及 **2026-11-20 最新多音源插件化重构、`FLOW Source Spec v1` 多配置兼容与 GitHub 多源 `SLP_LIVE_TEST=1` 端到端实测**（原内建 B 站专属模块与对应专属用例已抽离为外部未打包插件并新增 `SourceManagerTests` / `StandardSourcesTests` / `PluginImporterTests` / `MultiConfigCompatTests` / `ExternalBilibiliPluginTests`），完整基线请以以下最新基准文档为准：

- [SOURCE_SPEC.md](../SOURCE_SPEC.md)（`FLOW Source Spec v1` 多配置兼容标准）
- [AUDIT_REPORT.md](../AUDIT_REPORT.md)（全量验证基线与交付状态）
- [RELEASE_CHECKLIST.md](../RELEASE_CHECKLIST.md)（当前测试条数与构建门禁）
- [evidence/coverage.txt](../evidence/coverage.txt)（`xcrun xccov` 最近实测覆盖率）
- [交接日志](HANDOVER_LOG.md)（第 201–215 节最新交接记录）
