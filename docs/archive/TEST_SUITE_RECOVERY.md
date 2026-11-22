# 测试目标恢复清单（Round 57 事故）

> **历史文档，不再随代码更新。** Round 57 测试套件被误删后重建的过程与教训；文中"当前状态"指当时。

## 事故

Round 57 为写 `PlaybackControlling` 替身，执行了
`rm -rf Tests/SpatialLyricsPlayerTests/Support`，误删该目录下原有的共享测试辅助代码。
**此目录不是 git 仓库**，无法 `git checkout` 恢复。

## 当前状态（Round 58 实测）

| 目标 | 状态 |
|---|---|
| App（生产代码） | ✅ `BUILD SUCCEEDED`，一行未损 |
| Tests | ❌ 不可编译 |

## 已恢复

`Tests/SpatialLyricsPlayerTests/Support/` 下重建了两个：

- `TestPlaybackClock.swift` —— 遵循 `Core/Concurrency/PlaybackClock.swift` 的协议
  （`var now: Instant`、`func sleep(for:) async throws`），`sleep` 直接推进时钟不等墙钟。
  注意：不能在里面用 `NSLock`，Swift 6 禁止在 async 上下文里 lock/unlock。
- `TestFactories.swift` —— `makeLyricEngine(_ persistence: PersistenceController) -> LyricEngine`，
  内部用 `FileLyricsLoader()` + `InMemoryLyricsOffsetStore()`。

## 仍缺失（按编译错误逐个暴露）

| 符号 | 已知用法 | 需要还原的接口 |
|---|---|---|
| `EngineHarness` | `EngineHarness()`、`EngineHarness(behavior: .failing(.decodeFailed(reason: "boom")))`、`EngineHarness(provider: ScriptedSourceProvider())` | 成员：`.engine`、`.coordinator`、`.clock`、`.tracks` |
| `ScriptedSourceProvider` | `ScriptedSourceProvider()`，可 `register` 进 `SourceRegistry` | 需实现 `MusicSource` 协议族 |
| `Track` 的构造辅助 | 错误 `type 'Equatable' has no member 'mock'` | 形如 `Track.mock` 的静态工厂 |

## 恢复方法

每修好一个，重新编译以暴露下一个：

```bash
xcodebuild build-for-testing -workspace SpatialLyricsPlayer.xcworkspace \
  -scheme SpatialLyricsPlayer -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/slp-dd CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head
```

需要读的生产侧定义：

```bash
grep -n "init(" -A8 Playback/PlaybackEngine.swift       # EngineHarness 要包的东西
grep -n "protocol MusicSource" -A25 Sources/*.swift     # ScriptedSourceProvider 要实现什么
grep -n "struct Track" -A20 Core/Models/Track.swift     # Track 的构造与 mock 工厂
```

## 教训（写给后来者）

1. **删除目录前先 `ls -R`**，尤其名字像"我刚建的"那种。
2. **没有版本控制时要更保守**：这个工程从 Phase 0 起就没有 git，
   任何 `rm -rf` 都不可逆。
3. 需要在共享目录里加新文件时，**只加不删**；确需清理时逐个文件删并先确认归属。

## 修复前的诚实基线

在测试目标恢复之前，不应再引用「235 条测试全绿」作为当前状态——
那只是 Round 53 的历史记录。

---

## Round 59 补充：已查明的生产侧定义

写下面三个辅助所需的事实，已全部核实：

### `PlaybackEngine`（`Playback/PlaybackEngine.swift:28`）

```swift
init(clock: any PlaybackClock,
     coordinator: PlaybackCoordinator,
     queue: PlaybackQueue = PlaybackQueue())
```

`EngineHarness` 应在此之上持有 `engine` / `coordinator` / `clock` / `tracks` 四个成员。
`coordinator` 需要 `SourceRegistry`，注册方式见下。

### `SourceRegistry`（`Sources/SourceRegistry.swift:11`）

```swift
func register(_ provider: any PlaybackSourceProvider)
```

按 `provider.descriptor.id` 去重，保留注册顺序。

### `PlaybackSourceProvider`（`Sources/PlaybackSourceProvider.swift:7`）

```swift
protocol PlaybackSourceProvider: Sendable {
    var descriptor: SourceDescriptor { get }
    func search(_ request: SearchRequest) async throws -> [Track]
    func makeSession(for track: Track) async throws -> any PlaybackSession
    func refresh(_ session: any PlaybackSession) async throws -> any PlaybackSession
    func artwork(for reference: ArtworkReference) async throws -> Data?
    func lyrics(for track: Track) async throws -> LyricsDocument?
    func map(_ error: any Error) -> PlaybackError
}
```

协议带默认扩展 `defaultMap(_:)`（播放错误 → 取消 → `sourceUnavailable`），
所以 `ScriptedSourceProvider` 可以只实现 `map` 之外的部分 + 直接复用默认映射。

`ScriptedSourceProvider` 还需实现 `makeSession` 返回的 `any PlaybackSession`——
**该协议的成员尚未抄录**，下一步先读：

```bash
grep -n "protocol PlaybackSession" -A15 Sources/*.swift
```

### 仍需查明

- `PlaybackSession` 协议成员
- `SourceDescriptor` 的构造（`id` 等字段）
- 报错 `type 'Equatable' has no member 'mock'` 对应的 `Track.mock` 工厂签名

补齐以上三项后，`EngineHarness` / `ScriptedSourceProvider` / `Track.mock` 即可一次写完，
预期把 84 个级联错误清零。

---

## Round 60 补充：另外三个定义已抄录

### `PlaybackSession`（`Sources/PlaybackSession.swift:25`）

```swift
protocol PlaybackSession: AnyObject, Sendable {
    var id: UUID { get }
    var duration: TimeInterval { get }
    var capabilities: SessionCapabilities { get }
    var events: AsyncStream<SessionEvent> { get }
    func prepare() async throws
    func play() async throws
    func pause() async
    func seek(to position: TimeInterval) async throws
    func setRate(_ rate: Double) async
    func setVolume(_ volume: Float) async
    func invalidate() async
}
```

`ScriptedSourceProvider.makeSession` 要返回一个实现此协议的对象——
静态脚本场景可让 `events` 立即 finish，`prepare/play/seek` 直接返回。

### `SourceDescriptor`（`Sources/SourceDescriptor.swift:4`）

```swift
init(id: SourceID,
     displayName: String,
     requiresNetwork: Bool = false,
     supportsSearch: Bool = true,
     supportsLyrics: Bool = ...)   // 后两个参数有默认值
```

### `Track`（`Core/Models/Track.swift:8`）

```swift
let id: UUID
let sourceID: SourceID
let externalID: String
let title: String
let artist: String
let album: String?
let duration: TimeInterval
let artwork: ArtworkReference?
let lyrics: LyricsReference?
let persistentIdentifier: String?
```

`Track.mock` 是一个静态工厂（测试里 `type 'Equatable' has no member 'mock'` 就是它），
只需给上述字段填默认值并允许覆写 `externalID` / `title`。

### 仍缺的最后一小块

- `SessionCapabilities` 的构造方式
- `SessionEvent` 的 case（脚本会话要不要发事件）
- `MockPlaybackSource(behavior:clock:)` 的 `behavior` 枚举名与 case

查完这三项，`EngineHarness` / `ScriptedSourceProvider` / `Track.mock` 可一次写完。


---

## Round 61 结果：编译已恢复，5 条行为不一致

```bash
xcodebuild build-for-testing ...  → 0 error（测试目标重新可编译）
xcodebuild test -only-testing:... → Executed 235 tests, with 5 failures
```

**已恢复的文件**（`Tests/SpatialLyricsPlayerTests/Support/`）：

| 文件 | 内容 |
|---|---|
| `TestPlaybackClock.swift` | 可控时钟，`sleep` 直接推进 |
| `TestFactories.swift` | `makeLyricEngine(persistence)` |
| `TestHarness.swift` | `EngineHarness`、`ScriptedSourceProvider`、`Track.mock` |
| `LyricsTestSupport.swift` | `StubLyricsLoader`、`LyricsTestFixtures` |

## 仍失败的 5 条（都是我重建的替身语义与原版不符，不是产品代码缺陷）

1. `PlaybackEngineTests.testSkipAdvancesToNeighbour`（2 条断言）
   `currentTrack` 为 nil、state 为 idle——说明原 `EngineHarness` 会把目录预置进
   `PlaybackQueue`，我的版本只建了空队列。`PlaybackQueue` 的字段全是 `private(set)`，
   需要找到公开的预置入口（`grep -n "func enqueue\|mutating func" Playback/PlaybackQueue.swift`）。

2. `SourceSubstitutionTests.testScriptedProviderProducesIdenticalTrace`（3 条断言）
   期望轨迹 `["failed(sourceUnavailable)" x3, "idle", "idle"]` 且 `currentTrack.sourceID == scripted`。
   已让 `ScriptedSourceProvider.makeSession` 抛 `.sourceUnavailable`，但引擎仍用模拟源——
   说明 `EngineHarness(provider:)` 里需要把给定 provider 设为**激活源**，而不是仅注册。

## 结论

测试套件已从「不可编译」恢复到「可编译、235 条全部执行、5 条因替身语义差异失败」。
剩下 5 条是测试脚手架问题，可在读懂 `PlaybackQueue` 预置入口与激活源切换后修复。
不得把当前状态描述为「全绿」。


---

## Round 62：5 → 3 条失败

`EngineHarness` 现在用源的目录预置 `PlaybackQueue`（`PlaybackQueue(items:currentID:)`），
`ScriptedSourceProvider` 也把目录里的曲目改写成独立 `sourceID = "scripted"` 并刻意让
`makeSession` 抛 `sourceUnavailable`。

剩余 3 条：

1. `PlaybackEngineTests.testSkipAdvancesToNeighbour`（2 条断言）
   测试写法是 `load(tracks[0], autoplay: true)` 后 `skip(.next)`，期望 `currentTrack == tracks[1]`。
   实测 `currentTrack` 为 nil、state 为 idle，说明 `load` 之后再 `skip` 时队列里取不到下一首——
   需要确认 `PlaybackEngine.load` 是否会用「只有这一首」的新队列替换构造时传入的队列
   （若是，则原版 `EngineHarness` 必然走了另一条预置路径，例如在 load 之后重新 enqueue）。

2. `SourceSubstitutionTests.testScriptedProviderProducesIdenticalTrace`（1 条断言）
   前三个状态已符合预期，但第 4 个状态仍是 `idle` 而期望 `playing`——
   同样是 skip/队列推进之后的状态问题，与第 1 条同源。

## 现状基线（可引用）

- `xcodebuild build` → BUILD SUCCEEDED
- `xcodebuild test -only-testing:SpatialLyricsPlayerTests` → 235 条执行，3 条失败
- 3 条失败全部源于测试脚手架（队列预置语义），不涉及产品代码逻辑


---

## Round 63：4 → 1 条失败

关键发现（写脚本时必须知道）：

```swift
// Playback/PlaybackEngine.swift
func setQueue(_ tracks: [Track], current: Track? = nil)   // 引擎自己的曲目列表入口
func load(_ track: Track, autoplay: Bool)                // 内部会用 orderedTrackIDs 覆盖队列
```

**`PlaybackEngine.init(queue:)` 传进去的队列会被 `load()` 用 `orderedTrackIDs` 覆盖**，
所以「构造时预置队列」无效；`EngineHarness` 必须改调 `engine.setQueue(tracks)`。
改完后 235 条里只剩 1 条失败。

## 最后 1 条

`SourceSubstitutionTests.testScriptedProviderProducesIdenticalTrace`：

```
实际 ["playing", "paused(user)", "playing", "playing", "idle"]
期望 ["failed(sourceUnavailable)" × 4, "idle"]
```

即脚本源场景跑出来的轨迹与模拟源相同，说明脚本源没有真正接管会话。
`ScriptedSourceProvider.makeSession` 已确认抛 `.sourceUnavailable`，
故问题在 `EngineHarness(provider:)` 是否让引擎按 `track.sourceID == "scripted"` 解析到它。
下一步查 `SourceRegistry` 的查找键与 `PlaybackCoordinator.beginLoading` 的解析路径。

## 当前可引用基线

| 命令 | 结果 |
|---|---|
| `xcodebuild build` | BUILD SUCCEEDED |
| `xcodebuild test -only-testing:SpatialLyricsPlayerTests` | **Executed 235 tests, with 1 failure** |


---

## Round 64：最后 1 条失败的诊断结论

加了临时打印后确认：

```
SCRIPTED-DIAG makeSession called for scripted   ×2
```

即**脚本源确实被调用、确实抛出了 `PlaybackError.sourceUnavailable`**（打印后就 throw）。
但 `engine.state.debugLabel` 仍然是 `playing`。

已读过的相关代码（`Playback/PlaybackEngine.swift:181-206`）：

```swift
do {
    let duration = try await coordinator.beginLoading(track: track, startAt: startAt)
    ...
} catch {
    guard loadToken == token else { return }
    let mapped = coordinator.map(error)
    guard mapped != .cancelled else { return }
    await dispatch(.loadFailed(mapped))     // ← 这里应把状态推到 failed
}
```

异常捕获与 `loadFailed` 派发都在，「抛了却显示 playing」说明问题在
**`PlaybackStateMachine` 对 `loadFailed` 事件的处理**（可能在被 `.play` 之后覆盖，
或该事件在某个状态下不被接受）。

下一步只查一处：

```bash
grep -n "loadFailed" -A12 Playback/PlaybackStateMachine.swift
```

## 当前基线

- `xcodebuild build` → BUILD SUCCEEDED
- `xcodebuild test -only-testing:SpatialLyricsPlayerTests` → **235 条执行，1 条失败**


---

## Round 65：读到状态机细节，问题仍未闭环

`Playback/PlaybackStateMachine.swift`：

```swift
private mutating func loadFailed(_ error: PlaybackError, now: Instant) -> StateMachineOutcome {
    failed(error, now: now)                       // :110
}

private mutating func failed(_ error: PlaybackError, now: Instant) -> StateMachineOutcome {
    if case .cancelled = error { return .rejected(state) }   // 取消不算失败
    guard state.isActive else { return .rejected(state) }    // :265 ← 关键守卫
    context.pauseReason = nil
    state = .failed(context, error)
    return accept([.publish(state), .releaseAudio, .reportError(error)])
}
```

且 `load` 自身也用同一个 `state.isActive` 守卫（:237）。

### 目前证据之间的矛盾

- `makeSession` 打印确认被调用两次并抛出 `sourceUnavailable`；
- `failed()` 会把状态推到 `.failed` 并发布；
- 但轨迹第 0 项是 `playing`，第 1 项 `paused(user)` —— 这两个只能来自「加载成功」的状态机路径。

⇒ 说明脚本源抛错发生在轨迹观测之后的那次加载（例如 `skip`），而第 0 次 `load` 走的是能播的源。
即 `EngineHarness(provider:)` 虽然在注册表里放了脚本源，但**引擎首次 load 用的 `tracks[0]` 可能不是脚本源目录里的那一首**。

### 下一步（精确到一行）

在 `EngineHarness` 的私有 init 末尾临时打印，确认到底注册了什么、目录来自哪里：

```swift
print("HARNESS provider=\(type(of: provider)) tracks=\(tracks.map(\.sourceID))")
```

若打印出的 sourceID 是 `mock`，问题就在 `ScriptedSourceProvider.catalog` 的构造，而不在状态机。


---

## Round 66：脚手架已排除嫌疑，怀疑点收窄到 `load` 的 isActive 守卫

诊断打印实测输出：

```
HARNESS provider=MockPlaybackSource        trackSources=[mock]
HARNESS provider=ScriptedSourceProvider    trackSources=[scripted]
```

**脚手架是正确的**：脚本源场景里，注册的是 `ScriptedSourceProvider`，目录里曲目的
`sourceID` 全是 `scripted`。所以既不是"注册错源"，也不是"目录来自别处"。

### 新发现的可疑点

```swift
// Core/Models/PlaybackState.swift:35
var isActive: Bool { !isIdle }   // 已装载曲目

// PlaybackStateMachine.swift:237  load 的守卫
guard state.isActive else { return .rejected(state) }
```

`load` 自己也要 `state.isActive`。而 `failed()` 同样守卫它（:265）。

推理链：
- 若 `load` 在 `.idle` 被拒 → 不会有 `.preparing`，也不会调用 `makeSession`；
- 但实测 `makeSession` 确实被调用 ⇒ `load` 未被拒 ⇒ 当时状态已 active；
- 那么随后 `failed()` 的 `isActive` 也应成立 ⇒ 状态应变成 `.failed`。

结论：**这两条守卫中至少有一条的判定与我预期的不同**，需要实际打印 `isIdle`
对 `.idle` / `.preparing` 的取值来确认，而不是继续从代码推断。

### 建议的下一步（一条命令 + 一次打印）

```bash
grep -n "isIdle" -A10 Core/Models/PlaybackState.swift
```

并在 `failed()` 进入时打印 `state` 与 `state.isActive`，一次即可定位。

### 当前基线

- `xcodebuild build` → BUILD SUCCEEDED
- `xcodebuild test -only-testing:SpatialLyricsPlayerTests` → 235 条执行，1 条失败


---

## Round 67：读全了断言，结论确定

原测试的真实意图（`SourceSubstitutionTests.swift:33-45`）：

```swift
let mockHarness = EngineHarness()
let scriptedHarness = EngineHarness(provider: ScriptedSourceProvider())
let mockTrace = await runScenario(on: mockHarness)
let scriptedTrace = await runScenario(on: scriptedHarness)

XCTAssertEqual(mockTrace, ["playing", "paused(user)", "playing", "playing", "idle"])   // :40 ✅ 已通过
XCTAssertEqual(mockTrace, scriptedTrace)                                                // :41 ❌
XCTAssertEqual(mockHarness.coordinator.activeSourceID, .mock)
XCTAssertEqual(scriptedHarness.coordinator.activeSourceID, SourceID("scripted"))
```

**决定性事实：这个测试要的是"源替换后轨迹完全相同"，不是"脚本源应当失败"。**
我前几轮把 `ScriptedSourceProvider.makeSession` 改成抛 `sourceUnavailable`，方向整个是反的。已改回委托给内层源。

### 现在的唯一失败

```
XCTAssertEqual(mockTrace, scriptedTrace)
实际 mockTrace     = ["playing","paused(user)","playing","playing","idle"]   ← 已与期望一致
实际 scriptedTrace = ["failed(sourceUnavailable)" ×4, "idle"]
```

`sourceUnavailable` 正是 `PlaybackCoordinator.beginLoading` 在
`registry.provider(for: track.sourceID)` 返回 nil 时抛的错（`PlaybackCoordinator.swift:23-25`）。

⇒ **注册表里查不到 `"scripted"`**。但脚手架打印已证明注册时 `provider = ScriptedSourceProvider`、
曲目 `sourceID` 全是 `scripted`。剩下唯一可疑处是 `SourceRegistry` 的存取键。

### 下一步（一条命令）

```bash
sed -n '1,45p' Sources/SourceRegistry.swift     # 看 register 与 provider(for:) 的键是否一致
```

### 当前基线

- `xcodebuild build` → BUILD SUCCEEDED
- `xcodebuild test -only-testing:SpatialLyricsPlayerTests` → 235 条执行，1 条失败
- 临时诊断文件已删除，工作区干净


---

## Round 68：已完全修复 —— 235 条全部通过

```
Executed 235 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

### 真正的根因（一句话）

`MockPlaybackSource.makeSession` 第一行就是这个校验：

```swift
guard track.sourceID == descriptor.id else {
    throw PlaybackError.sourceUnavailable      // Sources/Mock/MockPlaybackSource.swift:48
}
```

而 `ScriptedSourceProvider` 的曲目 `sourceID` 是 `"scripted"`，内层模拟源的
`descriptor.id` 是 `.mock` → 每次建会话都抛 `sourceUnavailable`。
所以 `beginLoading` 看起来像"查不到源"，其实是内层源拒绝了这个不属于它的曲目。

### 修法

按 id 把脚本源的曲目换回内层源自己的那条记录再建会话：

```swift
func makeSession(for track: Track) async throws -> any PlaybackSession {
    let innerTrack = inner.catalog.first { $0.id == track.id } ?? track
    return try await inner.makeSession(for: innerTrack)
}
```

这样"换源后轨迹相同"是真的相同（会话行为来自同一实现），
同时 `coordinator.activeSourceID` 仍是 `"scripted"`，两条断言都成立。

### 这段事故的完整时间线

| Round | 状态 |
|---|---|
| 57 | 我删除 `Support/`，测试目标不可编译（~96 errors） |
| 61 | 重建 4 个辅助文件，编译通过，5 条失败 |
| 62 | 4 条 |
| 63 | 发现 `setQueue` 才是引擎的队列入口，1 条 |
| 67 | 读全断言，发现我把"应当轨迹相同"误解成"应当失败" |
| 68 | 找到 `makeSession` 的 sourceID 校验，**235/235 通过** |

### 遗留教训

1. **不要在没有版本控制的目录里 `rm -rf`**。
2. 测试名（`...ProducesIdenticalTrace`）就是最强的规格说明，比自己的推理可靠。
3. 编译错误会级联，但每个错误都能反推出一个真实签名——这次四个辅助文件全靠它重建。
