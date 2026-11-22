# FLOW / SpatialLyricsPlayer 代码审计报告

审计日期：2026-11-21  
审计范围：`SpatialLyricsPlayer` 全部生产代码（219 个 Swift 文件）与现行文档  
审计方式：文档阅读 + 静态代码审计 + 构建/测试基线复核 + 关键路径独立复现  
审计结论：**未发现 P0 级（可稳定复现的崩溃/全量数据丢失）问题；发现 P1 级问题 10 条、P2 级问题 38 条、P3 级问题 9 条。**  
说明：`需验证` 表示结论依赖真实 AppKit/SwiftUI 时序、故障注入或特定外部服务，需要按建议补测试确认；其余标为 `确认`。

> **这是 2026-11-21 的历史发现快照，不代表当前未修复数量。** 2026-11-22 已实现 P1-1…P1-10 的修复，以及播放 P2-1…P2-8、跨源剥头 P2-14；HLS 通过仅监听回环地址的受控代理逐跳处理列表、分片与密钥。当前验证结果和剩余发布缺口以 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) 为准。其他 P2/P3 不因上述修复自动视为闭环。

---

## 0. 基线验证

在生产代码未修改的工作区执行：

| 检查 | 结果 |
|---|---|
| `./Scripts/architecture-lint.sh` | `architecture-lint: OK` |
| `python3 Scripts/dead-code-scan.py` | `dead-code-scan: OK（没有零引用的类型）` |
| `./Scripts/check-doc-numbers.sh --skip-build-log` | `check-doc-numbers: OK`（16 张证据图、1167 条测试、覆盖率 67.17%） |
| `./Scripts/verify.sh --quick` | `verify: OK`；`Executed 1167 tests, with 8 tests skipped and 0 failures`（38.4 秒） |
| Release 构建 | `** BUILD SUCCEEDED **`，`warning:` 计数 0 |
| `git diff --check` | 通过；工作区无未提交改动 |

测试基线、文档数字与目录统计（各目录 Swift 文件数/行数）与文档一致，说明项目在**当前机器、当前提交**上可构建、可测试、静态闸门可复现。下面的问题主要是**代码正确性与安全边界**问题，不是“编译不过”。

---

## 1. 文档阅读结论

已阅读：

- `README.md`
- `docs/HANDOVER.md`
- `docs/ARCHITECTURE.md`
- `docs/AUDIT_REPORT.md`
- `docs/KNOWN_LIMITATIONS.md`
- `docs/RELEASE_CHECKLIST.md`
- `docs/FEATURE_MATRIX.md`
- `docs/NEXT_STEPS.md`
- `docs/SOURCE_SPEC.md`
- `docs/PERMISSIONS_AND_SANDBOX.md`
- `docs/IMMERSIVE_MODE.md`
- `docs/DESIGN_SYSTEM.md`
- `docs/RUNTIME_EVIDENCE.md`（含历史章节）

### 1.1 文档总体评价

- 产品定位、五种形态、九态播放机、`PositionAnchor`、单窗口形态、插件化音源架构等核心描述与代码结构基本一致。
- 目录文件数/行数统计精确：例如 `App/ 4/725`、`Core/ 20/1392`、`Sources/ 32/10144`、`Tests/ 177/21918`，实测完全一致。
- 测试基线 1167 条、8 跳过、0 失败，`verify.sh` 实测一致；覆盖率证据图计数 16 张也一致。
- 文档对“未做/未验证”的内容总体诚实，例如 UI 测试、真机听感、多显示器、VoiceOver、插件执行时限等均有登记。

### 1.2 文档与代码不一致之处

| # | 文档说法 | 代码事实 | 级别 |
|---|---|---|---|
| D1 | `HANDOVER.md:119`：“所有插件网络请求走 `PluginHTTPClient` 统一校验”；`KNOWN_LIMITATIONS.md:159`：“初始 URL 与每一跳重定向都会在发出前按 `allowedDomains` 校验” | 音频数据面没有走 `PluginHTTPClient`：`ProgressiveAudioStream.fetchData`、`MediaAudioCache.localFile` 直接 `URLSession.data`；HLS 直接交给 `AVURLAsset`。重定向和 segment 可绕过域名策略。详见 P1-1 | P1 |
| D2 | `RELEASE_CHECKLIST.md:13`：“生产代码 0 处 `try!` / `as! ` / `fatalError`” | `UI/Immersive/ImmersiveRenderer.swift:401` 存在 `required init(coder:) { fatalError(...) }`。该写法是 `NSCoder` 不可用路径的常见防御，但按文档的 grep 口径确实是 1 处 | P3 |
| D3 | `ARCHITECTURE.md:46`：表现层包括 `Privacy/` | 该目录已于 2026-11-21 删除（`HANDOVER.md:153` 也说明删除），`architecture-lint.sh` 也不再检查它 | P3 |
| D4 | `IMMERSIVE_MODE.md:15`：“暂停时胶囊与右上角按钮常显” | `UI/Immersive/ImmersivePlayerView.swift:229-241` 的 `autoHideLoop` 只有隐藏分支，没有在 `model.isPlaying == false` 时恢复 `chromeVisible`；暂停后控件可能仍隐藏，直到鼠标移动 | P2/P3 |
| D5 | `Playback/PlaybackStateMachine.swift:355-358` 注释：“当前生产代码不会发送 `.stallBegan`，音频是整段下载到本地再播（见 `BiliAudioCache`）” | 生产 `PlaybackEngine.swift:398-399` 明确发送 `.stallBegan/.stallEnded`；`HTTPStreamPlayerSession` 也会 yield `.stalled`。`BiliAudioCache` 类已不存在，注释与当前流式架构相反 | P3 |
| D6 | `Playback/PlaybackErrorPresentation.swift` 注释：“音源只有 B 站” | 当前已多音源化、B 站只是外部插件；属于遗留注释 | P3 |
| D7 | `Persistence/Schema/PlaylistRecord.swift` 注释：`itemKeys` 为 `sourceID|externalID` | 实际 `PlaylistEntry.key` 使用 `|`（内容一致），但 `TrackIdentity` 使用 `::`，两套复合键并存，容易让后续维护者混用 | P3 |
| D8 | `KNOWN_LIMITATIONS.md:158` 已承认插件执行时限未落地 | 代码属实；但该风险与本次发现的 `setTimeout(Infinity)` 崩溃叠加后，影响比文档描述更直接，见 P1-4 | P3（已知项补充） |

---

## 2. 代码审计发现

### 2.1 P1 — 高优先级

#### P1-1 插件音频数据面绕过 `allowedDomains` 与重定向校验（确认）

**位置**

- `Sources/Audio/ProgressiveAudioStream.swift:588-600`
- `Sources/Audio/MediaAudioCache.swift:374-408`
- `Sources/Audio/RemoteStreamSessionFactory.swift:11-18`
- `Sources/Plugins/JSONTemplateSource.swift:344`（只在 descriptor 创建时校验一次）
- `Sources/Plugins/JSPluginEngine.swift:936`（同上）

**证据**

音频层实际请求使用原始 `URLSession`，没有 `PluginHTTPClient` 的 `RedirectValidator`：

```swift
// ProgressiveAudioStream.swift:588-600
private func fetchData(url: URL, range: Range<Int64>) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    ...
    let (data, response) = try await session.data(for: request)
```

`MediaAudioCache.localFile` 同样直接 `session.data`；HLS 场景 `RemoteStreamSessionFactory` 返回 `.remoteStream`，由 `AVURLAsset` 自行拉取 playlist 与所有 segment，域名策略完全不参与。

**触发路径**

1. 插件 `allowedDomains: ["api.example.com"]`，返回 `https://api.example.com/stream/1`。
2. 该地址返回 302 到 `http://127.0.0.1:8080/`、`http://169.254.169.254/...` 或攻击者主机。
3. `ProgressiveAudioStream` / `MediaAudioCache` 自动跟随重定向；`descriptor.headers` 中的 Cookie、API Key、自定义头会随请求发出（`Authorization` 在跨主机时通常由 Foundation 剥离，但自定义头不保证）。
4. HLS 更直接：playlist/segment 可指向任意内网或外部地址。

**影响**

插件 `allowedDomains` 对音频数据面形同虚设；可被用于 SSRF、访问本机/内网服务、向第三方泄露插件请求头；HLS 场景完全失效。与 D1 的文档承诺不符。

**建议**

所有音频 HTTP 请求统一走 `PluginHTTPClient` 或等价的 `URLSessionTaskDelegate`；HLS 用 `AVAssetResourceLoaderDelegate` 代理 playlist/segment 并逐条校验；跨源重定向剥离 `Authorization`、`Cookie`、`Proxy-Authorization`、`X-Api-*` 等敏感头；拒绝 loopback、私有地址和链路本地地址；每次重定向重新检查联网开关。

---

#### P1-2 `MediaAudioCache.safeKey` 不可逆压缩导致缓存键碰撞、错歌与离线串库（确认）

**位置**

- `Sources/Audio/MediaAudioCache.swift:80-90`
- `Sources/Audio/MediaAudioCache.swift:485-506`
- `Sources/Audio/OfflineLibraryManager.swift:84-94`

**证据**

```swift
nonisolated static func safeKey(_ raw: String) -> String {
    let allowed = raw.map { character -> Character in
        character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
    }
    let name = String(allowed)
    return name.isEmpty ? "unknown" : name
}
```

`location(for:)` 和 `offlineLocation(for:)` 只用 `safeKey(cacheKey)` 作为文件名主体。`TrackIdentity.storageKey` 是 `sourceID::externalID`；中文、`-`、`/`、`:`、`+`、`=` 等全部压成 `_`。

**触发路径**

- `js-demo::a-b`、`js-demo::a_b`、`js-demo::a/b` 都得到 `js_demo__a_b`；
- 本地曲目路径 `/Music/歌曲一.mp3` 与 `/Music/歌曲二.mp3` 长度相同时通常得到同一个 `safeKey`；
- 同一 source、同一 qualityID/bandwidth/ext 下，第二首会命中第一首的缓存文件；`evict`/`removeOffline` 的前缀匹配还会删除其他曲目的缓存。

**影响**

播放错误歌曲、离线库串曲、删除离线保存时误删其他曲目；是数据完整性问题，不是简单性能问题。`OfflineLibraryManager` 的本地中文曲目离线保存也受影响。

**建议**

缓存文件名改用 `SHA-256(storageKey)` 或完整键的 Base64URL；保留可读前缀时附加 hash；禁止基于 `safeKey` 前缀做跨曲目检索；离线 manifest 保存原始完整键。

---

#### P1-3 `setTimeout(Infinity)` 可触发宿主 `Int(Double)` 运行时崩溃（确认）

**位置**

- `Sources/Plugins/JSPluginSandboxSupport.swift:201-204`
- `Sources/Plugins/JSPluginEngine.swift:471-476`

**证据**

JS 侧：

```js
function setTimeout(fn, delay) {
    var id = __flowNativeSetTimeout(Number(delay) || 0);
    ...
}
```

`Number(Infinity) || 0` 仍为 `Infinity`。Swift 侧：

```swift
let delayMs = max(0, Int(ms))
```

`Int(Double.infinity)` / `Int(Double.nan)` / 超出 `Int` 范围的值在 Swift 中会 trap，宿主进程直接退出。

**触发路径**

插件顶层或任意 API 调用中执行：

```js
setTimeout(() => {}, 1e999);
```

导入插件、启动恢复、搜索/取流时均可触发；属于未信任插件对宿主的可用性攻击。

**建议**

`scheduleTimer(ms:)` 先 `guard ms.isFinite`，再限制 `0...86_400_000`；JS 侧对 `Infinity`/`NaN` 直接忽略或抛错；不要在未校验的 Double 上调用 `Int()`。

---

#### P1-4 OpenSubsonic `format=raw` 流固定标成 `.mp3`，多高音质档共用缓存槽（确认）

**位置**

- `Sources/Standard/OpenSubsonicSource.swift:145-167`
- `Sources/Audio/MediaAudioCache.swift:88-90`
- `Sources/Audio/ProgressiveAudioStream.swift:182-226`
- `Integration/StreamingResourceLoaderBridge.swift:74-85`

**证据**

`.auto` / `.hifi` / `.lossless` / `.hiRes` 都请求 `format=raw`，但返回的 `AudioStreamDescriptor` 固定：

```swift
fileExtension: "mp3",
qualityID: quality == .standard ? 128 : (quality == .high ? 320 : 999),
bandwidth: quality == .standard ? 128_000 : (quality == .high ? 320_000 : 0),
```

即 `.auto/.hifi/.lossless/.hiRes` 共用 `qualityID=999`、`bandwidth=0`、`.mp3` 缓存文件名。`ProgressiveAudioStream` 用 descriptor 的扩展名写目标文件，不会调用 `MediaAudioCache.sniffAudioExtension`；`StreamingResourceLoaderBridge` 按 `.mp3` 声明 UTI。

**触发路径**

Navidrome/Subsonic 曲库为 FLAC，选择 `.auto` 或 `.lossless`：服务器返回 FLAC 字节，被写成 `...-999-0.mp3`，AVPlayer 可能解码失败；即使能播放，切换到其他高音质档位也会命中同一缓存文件。

**影响**

自建 FLAC 曲库常见路径下高音质播放失败/降质、缓存无法按档位区分、离线保存文件扩展名错误。

**建议**

首片响应后按 `Content-Type`/音频魔数确定扩展名并重命名；`AudioStreamDescriptor.fileExtension` 不再硬编码；缓存键加入实际音质档位或 URL 特征；`openMedia` 同步支持 alt-extension 查找；`StreamingResourceLoaderBridge` 使用真实格式 UTI。

---

#### P1-5 WebDAV `href` 可指向任意源，PROPFIND/封面/音频请求会携带 Basic 凭据（确认）

**位置**

- `Sources/Standard/WebDAVSource.swift:264-294`（`propfind` 无条件附加 `authHeaders()`）
- `Sources/Standard/WebDAVSource.swift:297-316`（`fetchData` 同样）
- `Sources/Standard/WebDAVSource.swift:414-420`（`resolveHref` 不校验同源）
- `Sources/Standard/WebDAVSource.swift:100-122`（音频 descriptor 带 `authHeaders()`）
- `Sources/Standard/WebDAVSource.swift:105-106`（`track.externalID` 可直接作为 URL）

**证据**

```swift
private func resolveHref(_ href: String) -> URL? {
    if let direct = URL(string: href, relativeTo: baseURL)?.absoluteURL {
        return direct
    }
    ...
}
```

服务端返回 `<D:href>http://attacker.example/cover.jpg</D:href>` 或 `http://127.0.0.1:8080/`，会被保留为外部主机；`propfind`/`fetchData` 会向该 URL 发送 `Authorization: Basic ...`。

**触发路径**

用户配置的 WebDAV 服务器被攻陷、或服务器返回被污染的 PROPFIND 响应 → 扫描/请求任意主机，携带 WebDAV 用户名与密码；音频与封面路径也会带 Basic 凭据。

**影响**

凭据泄露到第三方/内网服务，同时形成 SSRF；恶意 WebDAV 服务可让播放器访问本机接口。

**建议**

`resolveHref` 只接受 `http/https` 且 host/port 与 `config.baseURL` 完全一致；拒绝跨源 `href`；跨源请求绝不附加 `Authorization`；音频 URL 同样走域名白名单。

---

#### P1-6 损坏库只尝试最新一份备份，失败就直接建空库（确认）

**位置**

- `Persistence/PersistenceController.swift:82-87`
- `Persistence/PersistenceController.swift:361-366`

**证据**

```swift
if let url = resolvedURL, Self.isCorruptedFile(at: url) {
    self.quarantinedFileName = try Self.quarantineStore(at: url)?.lastPathComponent
    self.recoveredFromCorruption = true
    self.restoredFromBackup = Self.restoreFromLatestBackup(at: url)
}
```

`restoreFromLatestBackup` 只取 `latestBackup(for:)` 第一份；若该份主文件不可读或侧车复制失败，`restore` 返回 false，随后 `ModelContainer` 会在不存在的路径上创建**新空库**。`catch` 分支中本来有“新→旧逐份试备份”的循环（`:131-145`），但文件头损坏分支没有使用它。

**影响**

用户明明有多份可用旧备份，应用仍以空库启动，收藏、歌单、历史、歌词偏移表现为全部丢失。

**建议**

文件头损坏分支同样遍历 `backups(for:)`，逐份用 `ModelContainer` 实际打开验证；全部失败才创建空库；诊断页记录实际恢复的备份文件名。

---

#### P1-7 冷启动恢复未完成时 `saveNow()` 会把旧队列和进度覆盖为空（确认，需时序触发）

**位置**

- `Playback/PlaybackSessionPersistence.swift:45-55`（`saveNow`）
- `Playback/PlaybackSessionPersistence.swift:247-310`（`restore`）
- `App/AppDelegate.swift:157-163`（异步启动 restore）
- `App/AppDelegate.swift:186-191`（state 流立即订阅）
- `App/AppDelegate.swift:210-212、225`（失焦/退出调用 saveNow）

**证据**

`saveNow()` 没有任何“恢复未完成”门控，直接读取 `engine.queue` 和 `engine.currentTrack`：

```swift
func saveNow() {
    let queue = engine.queue
    let identity = engine.currentTrack?.identity
    ...
    upsertQueue(queue, in: context)
    upsertState(identity: identity, position: position, in: context)
    try? context.save()
}
```

`restore()` 在 `await tracks.all()`（`:256`）之后才读取 `stateRecord`（`:290`）；AppDelegate 却在启动时异步启动 restore，并同时启动 `statePersistenceTask`（`stateUpdates()` 先收到 `.idle`，1 秒后触发一次 `scheduleSave()`）。如果 `tracks.all()` 超过 1 秒，或用户在恢复期间切换应用/退出，`saveNow()` 会先把空队列和 `position=0` 写入数据库。

**影响**

冷启动后队列被清空、上次播放位置归零；`restore()` 可能读到刚写入的空状态并返回 false。

**建议**

增加 `hasRestored`/`isRestoring` 状态；恢复完成前 `saveNow()` 直接返回；把 `QueueRecord`/`PlaybackStateRecord` 的读取放在第一个 `await` 之前；或 AppDelegate 先 `await restore()` 再启用 `statePersistenceTask` 与保存回调。

---

#### P1-8 无 `.lrc` 的本地曲目会把整个音频文件当 LRC 读取（确认）

**位置**

- `Sources/Standard/LocalLibrarySource.swift:477-480`
- `Lyrics/LyricsLoading.swift:18-36`
- `Lyrics/LyricsLoading.swift:93-97`

**证据**

```swift
// LocalLibrarySource.swift:477-480
let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
let lyricsRef = FileManager.default.fileExists(atPath: lrcURL.path)
    ? LyricsReference(.file(lrcURL))
    : LyricsReference(.file(fileURL))   // 没有 .lrc 时指向音频文件
```

`FileLyricsLoader.sidecarDocument` 对 `.file` 引用直接 `Data(contentsOf:)`，没有扩展名/大小检查。`resolveAudioURL` 又只接受 `URL(string:).isFileURL`，而 `LocalLibrarySource.externalID` 是普通路径字符串，导致内嵌歌词分支也读不到。

**影响**

每次加载无 `.lrc` 的本地歌曲都会把几十到几百 MB 音频读入内存并尝试 UTF-8/GB18030 解码，可能卡顿/OOM；同时跳过内嵌歌词和外部歌词兜底。

**建议**

`FileLyricsLoader` 只把 `.lrc`/`.txt` 扩展名的 `.file` 引用当侧车文本；无 `.lrc` 时 `lyricsRef = nil`；`resolveAudioURL` 改用 `URL(fileURLWithPath:)`；`readDocument` 增加文件大小上限与二进制检测。

---

#### P1-9 「恢复默认布局」把窗口与状态机拆成两套状态（确认）

**位置**

- `Morph/MorphWindowController.swift:451-460`
- `Morph/MorphWindowController.swift:1278-1287`
- `Morphology/MorphologyEvent.swift:70-90`（`MorphologyState.current` 默认 `.expanded`）

**证据**

`resetPlacementMemory()` 直接重建默认状态机（`current = .expanded`），随后 `moveToDefaultPosition(for:)` 却固定使用 `PlayerMorphology.capsule` 的尺寸，且完全忽略传入的 `shape`；紧接着 `apply(.userRequested(defaultMorphology))` 在默认形态为 `.expanded` 时会被判为 redundant，`apply` 的守卫直接返回，`model.morphology` 不会更新。

**影响**

窗口变成 392×56 的胶囊，但状态机/内容仍认为是完整形态；用户点形态按钮可能被判 redundant，主界面布局错乱。多屏时还会固定回到主屏。

**建议**

重建状态机后同步 `model.morphology`/`model.isMorphologyLocked`；`moveToDefaultPosition` 使用传入的 `shape` 和当前屏幕；重新执行一次真实 transition。

---

#### P1-10 悬浮不透明度会污染完整播放器（确认）

**位置**

- `Morph/MorphWindowController.swift:289-295`（`start()` 无条件设 alpha）
- `Morph/MorphWindowController.swift:397-400`（`applyFloatingOpacity` 无条件设 alpha）
- `Morph/MorphWindowController.swift:1155-1167`（`configureWindow` 明确说明完整形态应常显）

**证据**

设置页的说明是“只作用于迷你条、胶囊与贴边；完整播放器始终不透明”（`UI/Settings/SettingsView.swift:1085`），但 `applyFloatingOpacity` 不判断 `machine.state.current`：

```swift
func applyFloatingOpacity(_ value: Double) {
    let clamped = CGFloat(LyricsOpacity.clamp(value))
    panel.alphaValue = clamped
}
```

用户在主窗口（expanded）里把“悬浮不透明度”拉到 0.3，整个主窗口（包括按钮和歌词）都会变成 0.3 透明。

**建议**

`start()` 与 `applyFloatingOpacity` 按 `machine.state.current == .expanded` 分支处理，完整形态固定 `alphaValue = 1`；只在悬浮形态应用悬浮透明度。

---

### 2.2 P2 — 中优先级

#### P2-1 `skip` 的 `requestNeighbor` effect 在 `await` 后无条件执行，覆盖用户随后选择（确认）

- **位置**：`Playback/PlaybackStateMachine.swift:239-253`、`Playback/PlaybackEngine.swift:220-228、273-303`
- **证据**：`dispatch` 顺序 `await perform(effect)`；`skip` 的 `releaseAudio` 会 `await coordinator.teardown()`，期间第二次 dispatch 可完整执行；恢复后 `requestNeighbor` 不检查状态与 token，直接 `neighbor(.next)` 再 `load`。
- **影响**：快速“下一首→选歌/停止”时最终播放的曲目不可预期；停止可能被忽略。
- **建议**：每次 dispatch 生成 operation token；每个 effect 前校验 `machine.state.trackID` 与 token；`requestNeighbor` 带 `originTrackID` 校验。

#### P2-2 元信息补全返回新的 `Track.ID` 时，标题/封面/歌词补全全部失效（确认）

- **位置**：`Sources/Plugins/JSPluginEngine.swift:762-785`、`Playback/PlaybackEngine.swift:107-121`、`Morph/MorphWindowController.swift:1377-1379`
- **证据**：`JSPluginSource.resolve` 返回 `Track(...)` 未传 `id: track.id`，默认生成新 UUID；`PlaybackEngine` 用 `resolved.id` 写入 `tracksByID`，但状态机 `trackID` 仍是旧 ID，下一次 `dispatch` 把 `currentTrack` 恢复为旧占位曲目；Morph 回调用 `model.track?.id == track.id` 也丢弃补全结果。
- **影响**：插件曲目的真实歌名、歌手、封面、歌词补全丢失，队列/资料库继续保存占位标题。
- **建议**：`JSPluginEngine.resolve` 显式传 `id: track.id`；`PlaybackEngine` 按 `identity` 归一化；Morph 回调改为比较 `identity` 而不是 `id`。

#### P2-3 旧会话的 `.failed` 事件在新曲目装载窗口内会错误失败新曲目（确认）

- **位置**：`Playback/PlaybackEngine.swift:330-343、390-397`
- **证据**：`dispatch(.load(B))` 先进入 `.preparing(B)`，`loadToken` 要等 `beginLoading(B)` 才更新；旧 `sessionEventsTask` 仍持有旧 token，旧会话 `.failed` 到达时 `token == loadToken` 仍成立，状态机接受 `.failed(B)`；随后 `beginLoading(B)` 看到状态不是 `.preparing` 直接返回。
- **影响**：切歌偶发直接报错/卡在失败，用户需手动重试。
- **建议**：接受 `.load/.sourceChanged` 时立即递增 `loadToken`；`handle(sessionEvent:)` 同时校验 `machine.state.trackID`。

#### P2-4 装载任务被取消时状态机永久停在 `.preparing`（确认）

- **位置**：`Playback/PlaybackEngine.swift:317-351`
- **证据**：`catch is CancellationError { guard loadToken == token else { return } }`，没有复位状态或产生 `.loadFailed`；`PlaybackCoordinator.beginLoading` 在 `makeSession` 后和 `prepare` 后都有 `Task.checkCancellation()`。
- **影响**：调用方任务取消（恢复任务、视图任务）后播放器停在“加载中”，后续播放被拒。
- **建议**：token 仍匹配且状态仍是该曲目 `.preparing` 时 dispatch `.stop` 或复位到 `.idle`。

#### P2-5 队列按易变的本地 `Track.ID` 判重，同一首歌会出现两个队列项（确认）

- **位置**：`Core/Models/Track.swift:5-7`、`Playback/PlaybackEngine.swift:99-100`、`Playback/PlaybackQueue.swift:114-121`
- **证据**：`Track.id` 是本地 UUID、每次搜索结果新建；`queue.jump(to:)` 只判断 UUID 是否在 items 中；同一 `(sourceID, externalID)` 的两个 Track 实例会插入两条。
- **影响**：队列重复、下一首/上一首顺序混乱、持久化后重启出现两份重复条目。
- **建议**：PlaybackEngine 建立 `TrackIdentity -> canonical Track.ID` 映射；所有 entry 按 identity 归一化；或让 PlaybackQueue 存 `TrackIdentity`。

#### P2-6 `setQueue(current: nil)` 与协议契约不符，播放中的当前曲目会从队列消失（确认）

- **位置**：`Playback/PlaybackControlling.swift:50-52`、`Playback/PlaybackEngine.swift:48-52`、`Playback/PlaybackQueue.swift:71-78`
- **证据**：协议说 `current == nil` 只替换列表、不动当前曲目；`queue.replace(items:current:)` 把 `currentID = nil`，`currentTrack` 却保留旧曲目。
- **影响**：队列界面没有当前行；持久化 `queue.currentID` 为 nil 而 `stateRecord` 还指向 A，下次恢复回落到列表第一首。
- **建议**：`current == nil` 时保留原 `queue.currentID`（如果仍在 newItems 中），或明确停止当前播放。

#### P2-7 `playbackFinished` 拒绝 `.seeking`，seek 接近结尾时永久停在“播放中”（确认）

- **位置**：`Playback/PlaybackStateMachine.swift:336-344`、`Playback/PlaybackEngine.swift:390-419`
- **证据**：`playbackFinished` 只接受 `.playing`/`.buffering`；`.seeking` 被 rejected，`finishCurrentTrack` 直接返回；之后 `seekFinished` 会回到 `.playing`，但 `.ended` 已消费，不再有下一首/循环。
- **影响**：拖到结尾或 seek 未返回时自然播完，进度停结尾、播放键语义混乱，不触发下一首。
- **建议**：`playbackFinished` 接受 `.seeking` 并保留/取消 `SeekTarget`；或记录 `pendingEnded` 在 `seekFinished` 后补发。

#### P2-8 单曲循环下“下一首播放”和手动下一首被吞掉（确认，需产品确认）

- **位置**：`Playback/PlaybackQueue.swift:191-196`、`Playback/PlaybackEngine.swift:136-139`
- **证据**：`advance()` 在 `.one` 分支先于 `nextUp/later` 返回 `currentID`；`skip(.next)` 使用 `queue.advance()`；`PlaybackQueueTests` 已把该行为固化为期望。
- **影响**：单曲循环下“下一首播放”永远轮不到，按下一首只是重载当前曲目。
- **建议**：区分自动重复与用户主动 advance，提供 `advanceForUser()`；若产品有意如此，则 UI 应禁用入口并更新文档。

#### P2-9 持久化错误被 `try?` 全面吞掉，界面显示成功但重启后数据消失（确认，条件触发）

- **位置**：`Playback/PlaybackSessionPersistence.swift:53、87-108`、`Persistence/Repositories/SwiftDataPlaylistStore.swift:37-83`、`Persistence/Repositories/SwiftDataLibraryStore.swift:11-47`、`Persistence/Repositories/SwiftDataLyricsOffsetStore.swift:36`、`Lyrics/LyricBindingStore.swift:112-113`
- **证据**：`try? context.save()` / `try? modelContext.save()`；`persistedTrackKeys.insert` 在真正 save 之前执行，写库失败后不会重试。
- **影响**：磁盘满、数据库锁、SwiftData 冲突时队列/收藏/歌单/歌词偏移静默丢失，无用户提示。
- **建议**：仓储方法改为 `throws`/`Result`；写失败回滚并上报；`persistedTrackKeys` 只在 save 成功后插入；恢复阶段 fetch 失败要返回诊断。

#### P2-10 `pendingPosition` 在“恢复后 seek 到 0”时不会清除，下次启动又跳回旧位置（确认）

- **位置**：`Playback/PlaybackSessionPersistence.swift:58-75、305-310`、`Integration/PlaybackRecoveryDriver.swift:110、156-185`
- **证据**：`positionToPersist` 只在 `currentPosition > 0.5 || state.isPlaying` 时清除 pending；恢复 42 秒后用户拖回 0，`state` 为 `.ready/.paused`、位置 0，仍返回 pending 42。
- **影响**：用户回到开头被旧值覆盖；离线恢复失败后自动恢复也从 0 开始。
- **建议**：`seekFinished`（包括 0）清除 pending；把 pending 通过恢复接口传给恢复驱动。

#### P2-11 插件/模板 ID 清洗碰撞导致文件覆盖、源 ID 冲突、Keychain 命名空间混用（确认）

- **位置**：`Sources/Plugins/SourceDomainPolicy.swift:140-150`、`Sources/Plugins/ImportedSourceStore.swift:307-342`、`Sources/Plugins/JSPluginEngine.swift:46-49、144-147`
- **证据**：`sanitizeID` 把非字母数字（除 `-`/`_`）映射为 `-`，`com.foo` 与 `com-foo` 都变成 `com-foo`；`persistFile` 直接覆盖同名文件；`sourceID` 与 Keychain namespace 都使用清洗结果。
- **影响**：两个插件文件静默覆盖、配置串源、用户凭据可能被另一个插件读取。
- **建议**：文件名/sourceID 使用 `SHA-256(rawID + originURL)`；导入时拒绝重复 sourceID；Keychain namespace 同样哈希。

#### P2-12 订阅清单/远程导入可 SSRF、读取 `file://` 本地文件、递归拉取无深度限制（确认）

- **位置**：`Sources/Plugins/ImportedSourceStore.swift:158-178、267-295`
- **证据**：`allowedDomains: []` 表示允许任意 http/https；`session.data(for:)` 自动跟随重定向；`url.isFileURL` 直接 `Data(contentsOf:)`；订阅条目 `importFromURL(remote)` 可返回另一个订阅，形成无限递归。
- **影响**：SSRF/内网探测、读取沙盒内本地文件、CPU/网络耗尽。
- **建议**：订阅条目统一走 `PluginHTTPClient`，只允许 https/公开域名；禁止订阅条目 `file://`；限制递归深度、条目数和总下载大小。

#### P2-13 插件/模板 HTTP 响应无大小上限，且可无限并发（确认）

- **位置**：`Sources/Plugins/PluginHTTPClient.swift:5-24`、`Sources/Plugins/JSPluginEngine.swift:321-426`、`Sources/Plugins/JSONTemplateSource.swift:518-545`
- **证据**：`session.data(for:)` 把完整响应体读入内存；每个 `flow.request` 创建独立 Task，无并发上限；响应同时保留 Data、字符串、解析对象。
- **影响**：恶意插件/模板可用数 GB 响应或上千并发请求耗尽内存/网络。
- **建议**：设置 `maxResponseBytes`；限制单插件并发与速率；解析前检查 `Content-Length`/实际字节数。

#### P2-14 `PluginHTTPClient` 重定向只校验域名，不清理 Cookie/自定义认证头（确认）

- **位置**：`Sources/Plugins/PluginHTTPClient.swift:40-60`
- **证据**：`willPerformHTTPRedirection` 只 `validate` URL，然后 `completionHandler(request)` 原样放行；跨 origin 时 `Cookie`、`X-Api-Key` 等自定义头可能保留。
- **影响**：多域名插件配置下 API Cookie/Token 泄露到 CDN 或其他白名单域。
- **建议**：跨 origin 时删除 `Authorization`、`Cookie`、`Proxy-Authorization`、`X-Api-*` 等；只保留安全头白名单。

#### P2-15 `ProgressiveAudioStream` 未校验 `Content-Range` 与请求区间一致，可能写错偏移/无限重试（确认）

- **位置**：`Sources/Audio/ProgressiveAudioStream.swift:207-224、472-512`
- **证据**：初始 206 直接采用 `parsed.start` 作为 `initialOffset`，不要求 `parsed.start == 0`；后续 `writeOffset = parsed.start` 不校验 `start/end` 与请求区间；`cursor = range.upperBound` 按请求区间而非实际写入区间推进。
- **影响**：CDN/代理返回错误起点时缓存永远不完整、播放卡死、持续请求。
- **建议**：严格校验 Content-Range 与请求范围完全匹配；非首片 200 视为完整响应并校验长度；不匹配终止并清理 `.part`。

#### P2-16 `MediaAudioCache.localFile` 把 206 分片当完整缓存，缺少 Content-Range/长度校验（确认）

- **位置**：`Sources/Audio/MediaAudioCache.swift:374-408`
- **证据**：请求没有 `Range` 头，却接受 `206`；只检查 `data.count > 64KB`，不检查 `Content-Range: bytes 0-(total-1)/total` 或 `Content-Length`。
- **影响**：错误代理返回的分片被写成最终缓存/永久离线文件，音频截断。
- **建议**：普通 GET 只接受 200；接受 206 时强制校验完整覆盖范围与 data.count == total。

#### P2-17 缓存命中只看“超过 64KB”，错误页/截断文件会被当成有效音频（确认）

- **位置**：`Sources/Audio/MediaAudioCache.swift:206-217、240-251、344-365`、`Sources/Audio/ProgressiveAudioStream.swift:228-232、536-545`
- **证据**：只按文件大小判断有效；`writeCompleteFile` 发现目标已存在直接返回，不替换旧文件；流式完成时若目标存在会删除新 `.part`，保留旧文件。
- **影响**：一首坏缓存永久污染，后续下载也无法修复。
- **建议**：缓存命中前验证音频魔数/MIME；保存完成标记；原子替换旧文件；解码失败自动删除坏缓存。

#### P2-18 `LocalLibrarySource.removeFolder` 使用字符串前缀删除，误删同前缀兄弟目录（确认）

- **位置**：`Sources/Standard/LocalLibrarySource.swift:104-115`
- **证据**：`indexedTracks.removeAll { $0.externalID.hasPrefix(path) }`；`/Music/A` 会命中 `/Music/AB/song.mp3`。
- **影响**：移除一个目录导致同前缀兄弟目录曲目从索引消失。
- **建议**：使用 `externalID == path || externalID.hasPrefix(path + "/")`。

#### P2-19 `shutdown()` 没有取消 `stateTask`、AX 观察和延迟任务（确认）

- **位置**：`Morph/MorphWindowController.swift:1373-1398、1764-1777、1943-1954`
- **证据**：`stateTask` 在 `guard let self` 后无限 `for await`，Task 强持有 self；`invalidateObservers` 只取消 `tickerTask` 和 `frameAnimator`，没有取消 `stateTask`、`evaluationTask`、`wallpaperTask`、`movePersistTask`，也没有 `axObserver.stop()`；`isStarted` 未复位。
- **影响**：控制器无法释放；shutdown 后状态流继续修改 model；AX 回调仍可能触发空间评估；最后 320ms 拖动位置可能丢失。
- **建议**：shutdown 统一取消所有 Task、停止 AX observer、`isStarted = false`，停止前同步保存 placement。

#### P2-20 `NSWorkspace` 通知 token 从错误的 NotificationCenter 移除（确认）

- **位置**：`Morph/MorphWindowController.swift:1765-1766、1807-1841`
- **证据**：`NSWorkspace.shared.notificationCenter.addObserver` 返回的 token 放入 `observers`，`invalidateObservers` 却统一用 `NotificationCenter.default.removeObserver(token)` 删除。
- **影响**：工作区激活/睡眠/Space 通知观察者不会被移除，测试或重建控制器时累积。
- **建议**：分别保存 `defaultObservers` 与 `workspaceObservers`，各自用对应 center 移除。

#### P2-21 鼠标穿透设置在“完整形态 → 悬浮”后丢失（确认）

- **位置**：`Morph/MorphWindowController.swift:252、1155-1167、2122`
- **证据**：`isInteractive` 从 `panel.ignoresMouseEvents` 反推；进入完整形态强制 `panel.ignoresMouseEvents = false`、`model.isInteractive = true`；回到悬浮后 `isInteractive` 已变 true，`persistPreferences` 把 `isClickThrough` 写回 false。
- **影响**：用户开启的穿透被静默关闭，悬浮歌词重新拦截鼠标。
- **建议**：把用户 `clickThrough` 偏好保存为独立状态，不要用窗口事件状态反推。

#### P2-22 位置锁定恢复和持久化都不完整（确认）

- **位置**：`Morph/MorphWindowController.swift:1187-1188、1260-1263、253、367-372`
- **证据**：`restore` 只设置 `model.isPositionLocked = snapshot.isLocked`，没有设置真正被 `isPositionLocked` 读取的 `positionLockOverride`；`togglePositionLock` 不调用 `persistPlacement`。
- **影响**：界面显示“已锁定”，实际自动避让仍可移动；重启后锁定状态丢失。
- **建议**：`restore` 设置 `positionLockOverride = snapshot.isLocked`；切换后立即持久化 placement。

#### P2-23 两种缩放路径都可能把完整窗口移出安全区（确认）

- **位置**：`Morph/MorphWindowController.swift:1030-1035、2014-2026`
- **证据**：`windowWillResize` 只有最小尺寸约束，没有最大/安全区约束；自绘 `resize(by:)` 限制宽高但不 clamp origin；`frame.origin.y = top - frame.size.height` 可为负。
- **影响**：窗口部分移出屏幕、压住 Dock/菜单栏或无法抓回。
- **建议**：`windowWillResize` 按 `screen.safeZone` 限制最大尺寸；`resize(by:)` 更新后整体 `clamped(into: zone, margin: 0)`。

#### P2-24 `ObstacleProvider` 会把 A 屏的在飞结果返回给 B 屏（确认）

- **位置**：`Spatial/ObstacleProvider.swift:66-71、89-108`
- **证据**：`refresh(_:)` 只要有 `refreshTask` 就直接 `await inFlight.value`，不比较 `request.screenFrame`；Task 只捕获创建时 request。
- **影响**：跨屏移动/插拔显示器时 B 屏拿到 A 屏裁剪后的障碍物数组，可能压到真实窗口。
- **建议**：在飞任务按 `ObstacleScanRequest`/display 为键；request 不一致时取消旧任务或重新按屏幕裁剪结果。

#### P2-25 `MorphWindowController.evaluateSpace(geometryOnly:)` 参数被完全忽略（确认）

- **位置**：`Morph/MorphWindowController.swift:1561-1567、1584-1605、1848-1849`
- **证据**：`geometryOnly` 从未读取，AX 几何回调传入 true 仍走完整 `performEvaluation`；`compensatingCheck` 已先 `refreshedObstacles`，随后又调用 `evaluateSpace` 触发第二次扫描。
- **影响**：拖动/缩放外部窗口时每 80ms 启动完整 planner 和重复 WindowServer 扫描，CPU 峰值与抖动风险高。
- **建议**：实现真正 geometry-only 路径；补偿检查复用已有 obstacle 结果。

#### P2-26 歌词视图每 125ms 重算整段布局和折行（确认，需性能复核）

- **位置**：`Morph/MorphWindowController.swift:1468-1479`、`UI/Expanded/LyricScrollView.swift:84-98、149-155`、`UI/Immersive/ImmersiveLyricsView.swift:256-258、298-303`
- **证据**：播放时 ticker 125ms 刷新 `model.lyric`；`LyricScrollView.body` 每次 `wrappedTexts(width:)` 并遍历全部 lines 做 `LyricScrollLayout.make`/字体测量。
- **影响**：100–300 行歌词长播时主线程每秒多次全量布局，低配机可能掉帧。
- **建议**：把当前位置拆成独立 observable；只在当前行/文档/窗口尺寸变化时重算，缓存 wrappedTexts 与布局；逐字高亮只更新当前行.

#### P2-27 沉浸页暂停后已隐藏的控件不会自动恢复（确认）

- **位置**：`UI/Immersive/ImmersivePlayerView.swift:229-241`
- **证据**：`autoHideLoop` 只有 `if chromeVisible, idle > 3, model.isPlaying ... { chromeVisible = false }`，没有 `model.isPlaying == false` 时恢复分支；暂停后条件不成立，循环空转。
- **影响**：与 `IMMERSIVE_MODE.md:15`“暂停时胶囊与按钮常显”不符；鼠标不动时用户看不到退出/播放控制。
- **建议**：循环内增加 `else if !model.isPlaying { chromeVisible = true }`，并恢复光标。

#### P2-28 背景画廊缩略图在 SwiftUI body 中同步等待 GPU（确认）

- **位置**：`UI/Immersive/BackgroundGalleryView.swift:16-33、107`、`UI/Immersive/ImmersiveRenderer.swift:340-362`
- **证据**：`BackgroundThumbnails.image` 是 `@MainActor`，在 `preview(_:)` body 中调用；内部 `renderer.update`/`settle`/`renderOffscreen`，`renderOffscreen` commit 后 `waitUntilCompleted` 并同步 `texture.getBytes`。
- **影响**：首次打开背景画廊要等待 pipeline 构建与多帧离屏渲染，主线程卡顿。
- **建议**：后台预生成 4 张缩略图，body 只读缓存；至少把 `renderOffscreen` 移到 Task 并用占位图先显示。

#### P2-29 歌词缓存文件名不是单射，前缀匹配会把别的曲目缓存当成自己的（确认）

- **位置**：`Lyrics/LyricDocumentCache.swift:18-44、77-83`
- **证据**：`safeComponent` 把 `/` 换成 `_`，不转义字面量 `_`；`matchingFiles` 用 `safeComponent(identity) + "_"` 前缀匹配；`local::/Music/A` 会命中 `local::/Music/A_B` 的缓存。
- **影响**：`loadAny(identity:)` 可能返回另一首歌的歌词；`remove` 可能删除别的缓存。
- **建议**：用完整 identity 的 SHA-256/Base64URL 作为文件名；不要用前缀匹配。

#### P2-30 AMLL TTML 解析器在 `<br/>`、嵌套 span、跨行空白时丢词/错时（确认）

- **位置**：`Lyrics/AMLLTTMLParser.swift:165-170、177、201-204、231-233`
- **证据**：`case "br": closeCurrent()` 会把当前行关闭，后续 `<span>` 文本因 `current == nil` 被丢弃；嵌套普通 span 的 `spanStart` 被内层覆盖；span 之间换行+缩进不是纯空格，被丢弃导致 `Helloworld`。
- **影响**：包含 `<br/>` 或格式化缩进的 TTML 少行、丢词、逐字时间错位。
- **建议**：`br` 结束当前行并创建下一行（行首取 p 的结束时间）；用栈保存每层 span 的 begin；对 span 间空白按 CJK 上下文决定是否补空格。

#### P2-31 LRC 词标签遇到未闭合 `<` 会重复前缀并丢掉后续文本（确认）

- **位置**：`Lyrics/LRCParser.swift:199-223`
- **证据**：找不到 `>` 时 `break`，但 `rest` 没有推进，`tail = String(rest)` 又把 `<` 前的 `I ` 追加一次；`[00:01.00]I <3 you` 解析为 `I I <3 you`。
- **影响**：歌词正文重复/缺失；`hasWordTiming` 被错误置 true。
- **建议**：未找到 `>` 时把 `String(rest[open...])` 作为剩余正文追加并结束循环；词标签只匹配时间格式，其他尖括号按字面保留。

#### P2-32 `LyricEngine.LoadState.failed` 永远不会被赋值，所有加载错误显示成“没有找到歌词”（确认）

- **位置**：`Lyrics/LyricEngine.swift:19、118-124`、`Lyrics/SourceAwareLyricsLoader.swift:23-35`
- **证据**：`guard let loaded else { ... state = .empty }`，没有错误分支；`SourceAwareLyricsLoader` 对 provider/external 都用 `try?`。
- **影响**：网络/源加载失败与“确实没有歌词”无法区分，UI 的 `.failed` 分支永远不显示。
- **建议**：`LyricsLoading` 返回 `Result` 或抛错；区分 `CancellationError`、网络错误和“无结果”；设置 `.failed` 并提供重试。

#### P2-33 最近播放先 `fetchLimit` 再去重，重复播放同一首会挤掉其他曲目（确认）

- **位置**：`Persistence/Repositories/SwiftDataLibraryStore.swift:15-31`
- **证据**：`descriptor.fetchLimit = max(1, limit)` 先取最近 N 条原始记录，再按 identity 去重；同一首歌连续播放 50 次时返回 1 条。
- **影响**：“最近播放”列表可能只剩一首。
- **建议**：先按 identity 去重/分组，再限制 distinct identity 数量。

#### P2-34 `RedactingLog` 对含空格路径和 URL userinfo/路径脱敏不完整（确认）

- **位置**：`Core/Utilities/RedactingLog.swift:21-44`
- **证据**：路径正则 `(?:/[^\s/:]+){2,}` 遇到空格即停止；`failed to open /Users/alice/My Documents/secret-song.mp3` 会保留 `Documents/secret-song.mp3`；URL 正则只处理 query，不清理 userinfo 和 path。
- **影响**：日志/诊断可能泄露用户目录、文件名、订阅地址中的账号或路径令牌。
- **建议**：用 `URLComponents` 清除 user/{{PASSWORD}} 并整体折叠 path；文件路径按路径组件解析，支持空格。

#### P2-35 `FileLyricsLoader` 只尝试 UTF-8/GB18030，UTF-16 LRC 解出 NUL 乱码（确认）

- **位置**：`Lyrics/LyricsLoading.swift:39-48`
- **证据**：UTF-16LE 无 BOM 的文本用 UTF-8 解码会“成功”返回含 NUL 的字符串，不会进入 GB18030；UTF-16 带 BOM 也只会得到乱码。
- **影响**：Windows 保存的 UTF-16 LRC 显示乱码、时间轴丢失。
- **建议**：检测 BOM，依次尝试 `.utf16`/`.utf16LittleEndian`/`.utf16BigEndian`；UTF-8 解码后若含大量 NUL 则拒绝再尝试 GB18030。

#### P2-36 `PersistenceController` 隔离损坏库时侧车移动失败会被当成孤儿删除，同一秒第二次隔离还会抛错（确认，罕见文件错误）

- **位置**：`Persistence/PersistenceController.swift:232-247、255-260`
- **证据**：主库移动成功后侧车用 `try?` 移动；`removeOrphanSidecars` 发现主库不存在就删除残留 WAL；目标文件名时间戳到秒，同一秒第二次隔离 `moveItem` 目标已存在抛错。
- **影响**：隔离副本丢失未 checkpoint 数据；极端情况下恢复流程中断。
- **建议**：用 UUID/纳秒级目录确保唯一；先完整复制确认后发布；侧车移动失败保留原文件并记录错误。

#### P2-37 `ServerSourceConfig` 未剥离 URL userinfo，密码可能明文进入 UserDefaults（确认）

- **位置**：`Sources/Standard/ServerSourceConfig.swift:40-55、120-123`、`UI/Settings/SettingsView.swift:815-820`
- **证据**：`normalizedBaseURL` 保留 `components.user`/`口令`；`ServerSourceConfigStore` 用 `JSONEncoder` 把 config 写入 `sources.standardServers` UserDefaults；表单直接保存用户输入的 URL。
- **影响**：用户粘贴 `https://user:***@host` 这类带凭据的地址时密码不以 Keychain 存储，而是明文进入偏好/备份。
- **建议**：`normalizedBaseURL` 强制清空 user/口令并对含 userinfo 的输入报错；密码只写 Keychain。

#### P2-38 本地化覆盖门禁只扫描部分语法，英文模式仍有大量中文（确认）

- **位置**：`Tests/SpatialLyricsPlayerTests/UI/LocalizationCoverageTests.swift:27-41`（只扫 `Text|Button|Label|Toggle|Picker` 且只扫 `UI/Morph/MenuBar`）；以下代码绕开门禁：
  - `MenuBar/MenuBarView.swift:200-212` 的 `toggleRow(_ title: String...)`，调用 `toggleRow("隐私模式"...)`、`toggleRow("悬浮歌词"...)`（`:138、143`），以及 `Button("\(minutes) 分")`（`:183`）；
  - `UI/Expanded/AuxiliaryDrawer.swift:584-626` 的 `group/toggleRow/sliderRow` 均接收 `String`，调用点 `:517-557`；
  - `Morphology/Morphology.swift:43-50`、`Overlay/LyricsShape.swift:15-20`、`Lyrics/LyricLayout.swift:10-14`、`System/BackgroundAppearance.swift:10-13`、`Morphology/AutoExpandPolicy.swift:24-36` 返回裸中文；`UI/Settings/SettingsView.swift:981、1014、1076、1220、1241、1275、1281、1296` 用 `Text(String)` 展示（verbatim，不查表）；
  - `Shared/PlaybackSnapshot.swift:84-86`、`SpatialLyricsWidgets/WidgetEntryView.swift:44-53、159`、`Integration/SystemMediaIntegration.swift:114`、`Integration/PrivacyState.swift:98` 的“正在播放/未在播放/播放中/已暂停/接下来”等；
  - `Integration/SettingsBackup.swift:60-64`、`Integration/LaunchAtLogin.swift:26-29` 的错误文案。
- **影响**：英文系统下菜单栏快捷开关、快速设置抽屉、设置页的形态/布局/外观下拉、小组件状态、系统“正在播放”隐私占位等仍显示中文；与 `RELEASE_CHECKLIST.md:22`“551 条双语键全覆蓋”形成假象。
- **建议**：把枚举 `displayName` 改为 `String(localized:)`；`toggleRow/group/sliderRow` 参数改为 `LocalizedStringKey`；把 `Shared/`/`Widgets/` 纳入本地化扫描；对 `String(localized:)` 生成的实际展示做 UI 断言，而不只检查目录键。

### 2.3 P3 — 低优先级与工程质量

| # | 位置 | 问题 | 状态 |
|---|---|---|---|
| P3-1 | `Persistence/SpatialLyricsMigrationPlan.swift:9-23`、`Schema/SpatialLyricsSchemaV1.swift:8-18` | V1/V2/V3 共享同一组可变 `@Model` 类；一旦给 `TrackRecord` 等加字段，历史 schema 形状随之改变，旧库迁移可能失败 | 需验证 |
| P3-2 | `Morph/MorphWindowController.swift:2108-2109` | `preferredX/Y` 写入绝对坐标，但 `PlacementSnapshot` 约定是 0…1 归一化坐标；`preferredOrigin` 生产调用全是 nil，位置记忆实际不参与评分 | 确认 |
| P3-3 | `Morphology/MorphologyEngine.swift:53-195`、`Spatial/SpatialStateMachine.swift:46-137` | 两个纯逻辑引擎在生产路径没有实际调用者；生产使用 `AdaptivePlacementPlanner`，测试仍覆盖旧引擎，文档与生产行为可能分叉 | 确认 |
| P3-4 | `Sources/Audio/MediaAudioCache.swift:17` vs `Sources/Standard/LocalLibrarySource.swift:17-19` | `aiff/aif/alac` 不在缓存支持集合，导致本地 AIFF/ALAC 离线保存“成功但不可用”，`OfflineLibraryManager.refresh` 会删除记录 | 确认 |
| P3-5 | `Sources/Audio/ProgressiveAudioStream.swift:139`、`MediaAudioCache.swift:137-165` | `.part` 临时文件不计入 500MB 配额，普通清理路径不删除；崩溃后可能长期残留 | 确认 |
| P3-6 | `Lyrics/TextNormalizer.swift:12-23`、`Lyrics/LyricQueryNormalizer.swift:23-26` | `CFStringTransform` 会把“乾隆→干隆/瞭望→了望”等过度转换；查询归一化全局删除 `mv`，`MVP` 变 `p` | 确认 |
| P3-7 | `docs/RELEASE_CHECKLIST.md:13`、`UI/Immersive/ImmersiveRenderer.swift:401` | 文档声称生产代码 0 处 `fatalError`，实际 required `init(coder:)` 有一处；属于文档口径问题，不是运行时风险 | 确认 |
| P3-8 | `docs/ARCHITECTURE.md:46` | 仍列已删除的 `Privacy/` 目录；`architecture-lint` 已不检查它 | 确认 |
| P3-9 | `Playback/PlaybackStateMachine.swift:355-358` | 注释称生产不会发送 `.stallBegan`、引用已不存在的 `BiliAudioCache`；实际 `PlaybackEngine.swift:398-399` 会发送 | 确认 |

---

## 3. 修复优先级建议

1. **先修 P1-1、P1-2、P1-5**（插件网络边界、缓存键、WebDAV 凭据）：这三条影响安全/隐私与数据完整性，且不需要大改架构。
2. **再修 P1-3、P1-4**（插件定时器崩溃、OpenSubsonic 容器/缓存）：都是用户可见的崩溃或播放失败，改动局部。
3. **数据恢复与本地歌词 P1-6、P1-7、P1-8**：涉及用户数据与本地音乐主链路；建议先补故障注入测试（损坏库、启动即失焦、无 lrc 的本地歌）。
4. **P1-9、P1-10**（恢复默认布局、悬浮不透明度）：设置页可见 bug，建议补 UI 契约测试。
5. P2 级：优先处理播放竞态（P2-1 至 P2-8）、持久化静默失败（P2-9）、插件导入与重定向（P2-11 至 P2-14），再处理窗口/歌词性能与本地化覆盖。
6. P3 级：随重构顺手清理，尤其是把 `MorphologyEngine`/`SpatialStateMachine` 接入生产或明确删除，避免文档与测试继续制造“已覆盖”的假象。

---

## 4. 可以直接补的测试清单

- 损坏库：构造 3 份备份，最新一份损坏，验证回退到第二份而不是空库。
- 启动恢复：用延迟 `tracks.all()` 的 Fake Repository，在 restore 未完成时调用 `saveNow()`，断言不覆盖旧队列/进度。
- 本地歌词：无 `.lrc`、纯音频文件 + 内嵌歌词，断言不读取整段音频、优先读内嵌/外部。
- 缓存键：中文/带 `-`、`_`、`/` 的 externalID，断言两个不同 Track 不共享缓存路径。
- JS 插件：`setTimeout(() => {}, Infinity)`、`1e999`、`NaN` 均不崩溃。
- 插件网络：音频 URL 302 到 loopback/其他 host，断言被拒绝；HLS segment 指向非白名单 host，断言被拒绝。
- WebDAV：PROPFIND 返回 `<href>http://evil</href>`，断言不请求、不带 Authorization。
- 播放竞态：在 `releaseAudio` 挂起时注入第二次 `load(C)`，断言最终是 C；旧会话 `.failed` 不失败新曲目。
- 窗口：`resetPlacementMemory()` 后断言 `model.morphology == machine.state.current` 且窗口尺寸匹配；expanded 修改 opacity 断言 alpha==1；穿透开启后 expanded→capsule 断言仍穿透。
- 本地化：扫 `String(localized:)` 不可见的动态字符串，或在英文 locale 下渲染 MenuBar/QuickSettings/Settings/Widget 快照。

---

## 5. 结论

项目工程质量整体较高：分层、静态闸门、测试基线、文档口径都明显优于一般单人项目；播放状态机、空间求解、插件兼容层的注释也记录了真实踩坑过程。当前最值得优先处理的不是“大重构”，而是三类收口：

1. **插件网络边界必须覆盖音频/HLS 数据面，而不能只覆盖元数据请求**；
2. **缓存键、备份恢复、本地歌词读取这类“看起来只是性能层”的代码，实际会造成错歌或数据丢失**；
3. **窗口层存在若干状态不同步与清理不完整问题，建议在继续叠加沉浸/多屏功能前先把 Morph 状态与窗口状态的单一事实来源收紧**。

完成上述 P1 与关键 P2 后，再按 `RELEASE_CHECKLIST` 的 release 流程补一次 `--live` 与 `SLP_AUDIO_TEST=1`，即可把当前“静态闸门全绿、运行语义仍有边界漏洞”的状态收口。
