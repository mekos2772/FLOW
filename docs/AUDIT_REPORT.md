# 审查报告

> 本文记录历次审查的范围、发现、证据与现状。按**严重度**排序，
> 每条都给出证据来源（节号 / 测试名 / 命令），便于核对而不是听我描述。
> **2026-11-22 状态修正**：第〇节是 11-21 的历史发现清单；当前已实现全部十项 P1、播放 P2-1…P2-8 和跨源请求头 P2-14 的修复。逐项证据与剩余发布缺口见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。未单独复核的其余 P2/P3 保留开放。
> **最近一次全量审计是 2026-11-21（历史发现逐条见 [CODE_AUDIT_2026-11-21.md](CODE_AUDIT_2026-11-21.md)）**；
> 第一至六节是 2026-11-16 审查的原始结论，表里的"第 N 节"指 [交接日志](archive/HANDOVER_LOG.md)；第七、九节随后续版本更新。

## 〇、2026-11-21 全量代码审计（未闭环）

对全部 219 个生产 Swift 文件逐层审计 + 文档逐份核对 + 关键路径独立复现。
基线复核（2026-11-21 审计当时；现行基线见 [上线清单](RELEASE_CHECKLIST.md)）：`verify.sh --quick` 全绿（1167 条测试、8 跳过、0 失败），Release 构建 0 警告，
`architecture-lint` / `dead-code-scan` / `check-doc-numbers` 全通过，工作区无未提交改动。
**未发现 P0；P1 级 10 条、P2 级 38 条、P3 级 9 条。**

### P1（安全边界 / 数据完整性 / 用户可见错误）

| # | 问题 | 关键证据 |
|---|---|---|
| 1 | 插件音频数据面绕过 `allowedDomains` 与重定向校验：302 / HLS segment 可指向 loopback、内网或任意主机（SSRF + 请求头泄露） | `Sources/Audio/ProgressiveAudioStream.swift:588-600`、`MediaAudioCache.swift:374-408`、`RemoteStreamSessionFactory.swift:11-18` |
| 2 | `MediaAudioCache.safeKey` 把所有非 ASCII 字母数字压成 `_`：不同曲目命中同一缓存文件，离线删除误删邻曲 | `MediaAudioCache.swift:80-90`（本地复现：`js-demo::a-b` / `a_b` / `a/b` 同键） |
| 3 | 插件 `setTimeout(Infinity)` → `Int(Double.infinity)` trap，宿主直接退出 | `Sources/Plugins/JSPluginEngine.swift:471-476`、`JSPluginSandboxSupport.swift:201-204` |
| 4 | OpenSubsonic `format=raw` 流固定标 `.mp3`，`.auto/.hifi/.lossless/.hiRes` 共用缓存槽，FLAC 曲库播放失败/串档 | `Sources/Standard/OpenSubsonicSource.swift:145-167` |
| 5 | WebDAV `href` 不做同源校验：服务端可让 PROPFIND/封面/音频请求带 Basic 凭据指向任意主机 | `Sources/Standard/WebDAVSource.swift:264-316、414-420` |
| 6 | 损坏库只尝试最新一份备份，失败直接建空库（旧备份不遍历） | `Persistence/PersistenceController.swift:82-87、361-366` |
| 7 | 冷启动恢复未完成时 `saveNow()` 把空队列与 0 进度覆盖旧数据 | `Playback/PlaybackSessionPersistence.swift:45-55、247-310` |
| 8 | 无 `.lrc` 的本地曲目把整个音频文件当 LRC 读（大文件读入内存 + 内嵌歌词分支不可达） | `Sources/Standard/LocalLibrarySource.swift:477-480`、`Lyrics/LyricsLoading.swift:18-36、93-97` |
| 9 | 「恢复默认布局」窗口用胶囊尺寸、状态机记 expanded，两套状态脱节 | `Morph/MorphWindowController.swift:451-460、1278-1287` |
| 10 | 「悬浮不透明度」设置污染完整播放器（expanded 下整窗变透明） | `Morph/MorphWindowController.swift:289-295、397-400` vs `:1155-1167` |

### P2（38 条，按子系统摘记，全表见详报）

- **播放竞态**（P2-1…P2-8）：`skip` 的 `requestNeighbor` effect 在 `await` 后无 token/状态校验；元信息补全返回新 `Track.ID` 使标题/封面/歌词补全全部丢弃（`JSPluginEngine.swift:775-785`）；旧会话 `.failed` 在装载窗口误伤新曲目；装载取消后状态机停 `.preparing`；队列按易变 `Track.ID` 判重；`setQueue(current: nil)` 违背协议契约；`playbackFinished` 拒绝 `.seeking` 导致结尾停住；单曲循环吞掉"下一首播放"。
- **持久化静默失败**（P2-9）：`try? context.save()` 遍布，`persistedTrackKeys` 在 save 前插入导致写库失败不重试；`pendingPosition` 在 seek 回 0 后不清（P2-10）。
- **插件导入与网络**（P2-11…P2-14）：`sanitizeID` 碰撞致文件覆盖与 Keychain 命名空间混用；订阅清单 SSRF/`file://`/无递归上限；响应无大小/并发限制；重定向不剥离 Cookie/认证头。
- **音频缓存**（P2-15…P2-17）：`Content-Range` 未校验；206 分片可当完整缓存；命中只看 >64KB，坏缓存永久污染。
- **源侧**（P2-18）：`removeFolder` 字符串前缀误删同前缀兄弟目录。
- **窗口层**（P2-19…P2-25、P2-27、P2-28）：`shutdown()` 不取消 `stateTask`/AX/延迟任务；`NSWorkspace` token 从错误 NotificationCenter 移除；穿透设置在 expanded→floating 后丢失；位置锁定恢复/持久化不完整；两条缩放路径可越出安全区；`ObstacleProvider` 跨屏返回旧屏结果；`evaluateSpace(geometryOnly:)` 参数被忽略且补偿路径二次扫描；沉浸页暂停后控件不恢复；背景画廊缩略图在 body 内同步等 GPU。
- **歌词与持久化**（P2-29…P2-37）：歌词缓存文件名前缀匹配非单射；AMLL TTML `<br/>`/嵌套 span 丢词错时；LRC 未闭合 `<` 重复前缀；`LoadState.failed` 永不可达；`recent()` 先 fetchLimit 再去重；`RedactingLog` 对空格路径与 URL userinfo 脱敏不完整；UTF-16 LRC 乱码；隔离损坏库时侧车可被误删；`ServerSourceConfig` 不剥离 URL userinfo。
- **本地化**（P2-38）：覆盖门禁只扫 `Text|Button|Label|Toggle|Picker` 且只扫 `UI/Morph/MenuBar`，`toggleRow`/`sliderRow`/`enum displayName`/`Text(String)` 及 `Shared/`/`SpatialLyricsWidgets/` 里的中文在英文模式外露。

### P3（9 条）

V1–V3 schema 共享可变 `@Model`；`preferredX/Y` 写绝对坐标且 `preferredOrigin` 恒 nil；`MorphologyEngine`/`SpatialStateMachine` 未接入生产决策路径（测试在测旧引擎）；`aiff/aif/alac` 不在缓存支持集（离线保存此类文件"成功但不可用"）；`.part` 不计入 500MB 配额且普通清理不删；`CFStringTransform` 过度转换（乾→干）+ `normalize` 全局删 `mv`；`RELEASE_CHECKLIST` 称 0 处 `fatalError` 实有 1 处（`ImmersiveRenderer.swift:401`）；`ARCHITECTURE.md` 仍列已删除的 `Privacy/`；`PlaybackStateMachine.swift:355-358` 注释引用已删除的 `BiliAudioCache` 且与现行流式实现相反。

### 文档不一致（已核对）

`HANDOVER.md:119`、`KNOWN_LIMITATIONS.md:159` 声称插件所有网络请求与每跳重定向都走 `PluginHTTPClient`——只对元数据请求成立，音频数据面不成立（P1-1）。`IMMERSIVE_MODE.md:15` 称暂停时控件常显——`ImmersivePlayerView` 无恢复分支（P2-27）。详表见详报第 1.2 节。

### 修复优先级（与详报第 3 节一致）

先修 P1-1 / P1-2 / P1-5（插件网络边界、缓存键、WebDAV 凭据），再修 P1-3 / P1-4（插件定时器崩溃、OpenSubsonic 缓存），随后补故障注入测试收口 P1-6…P1-8 与窗口两条（P1-9/P1-10）。

---

## 历史审查记录（2026-11-16）

## 一、严重（会造成数据丢失或用户误判）

| # | 问题 | 影响 | 证据 | 状态 |
|---|---|---|---|---|
| 1 | 测试一直在写**使用者的真实数据库** | 早先"收藏被清空"的真正原因 | 第 85 节；修复后真机库行数不变 | 已修 + 备份恢复兜底 |
| 2 | 播放会话存在**跨执行器数据竞争** | `duration`/`item` 被后台写、主线程读 | 第 127/128 节；崩溃栈证明 `prepare()` 跑在全局执行器 | 已修（入口 + KVO 全部归主 actor） |
| 3 | 音量 0 被当成"没设置" → 重启变**满音量** | 静音失效、突然出声 | 第 109 节；`SettingsClampingTests` | 已修 |
| 4 | 脏数据兜底 `?? Data()` 会**覆盖好快照** | 队列凭空消失 | 第 111 节 | 已修（失败则不写） |
| 5 | Widget 崩溃后永久显示"正在播放" | 桌面小组件长期说谎 | 第 131/137 节；`SnapshotFreshnessTests` | 已修 |
| 6 | Widget 每秒重载触发系统限流 | 小组件停止更新 | 第 98 节；`WidgetReloadThrottleTests` | 已修 |

## 二、功能缺失（文档写了、代码没做）

| # | 问题 | 影响 | 证据 | 状态 |
|---|---|---|---|---|
| 7 | 点小组件空白处**没有任何反应** | 用户以为 App 坏了 | 第 136 节 | 已修（`widgetURL` + scheme 对拍） |
| 8 | 首页无内容时**一片空白** | 首次启动/未联网时无从下手 | 第 115 节；`docs/evidence/home-*.png` | 已修（空态 + 引导） |
| 9 | 时长超过 1 小时显示成 `60:00` | 长音频时长错误 | 第 90 节；`DurationTextTests` | 已修（`1:00:00`） |
| 10 | UI 冒烟测试断言的是**早已删除**的骨架文案 | 测试永远失败（且没人跑） | 第 96 节 | 已修 + 改为内存库启动 |

## 三、用户可见的文案问题

| # | 问题 | 影响 | 证据 | 状态 |
|---|---|---|---|---|
| 11 | 自定义错误未实现 `LocalizedError` | 显示 `The operation couldn't be completed…` | 第 146 节；`LocalizedFailureTextTests` | 已修（2 处） |
| 12 | 播放错误文案拼进 AVFoundation 技术串 | 界面出现 `AVFoundationErrorDomain error -11800` | 第 147 节；`PlaybackErrorCopyTests` | 已修 |
| 13 | 39 条界面文案没进字符串目录 | 英文模式露中文 | 第 92 节；`LocalizationCoverageTests` | 已修（277 条全覆盖） |
| 14 | HTTP 状态码被丢弃，错误信息为空 | 失败时"什么都没有" | 第 87/103 节 | 已修（用状态码 + 可读信息） |

## 四、静默失效（不报错但不对）

| # | 问题 | 影响 | 证据 | 状态 |
|---|---|---|---|---|
| 15 | 容器构建失败时**静默**退到示例曲库 | 用户以为 App 坏了 | 第 122 节；`DegradedModeTests` | 已修（设置页 + 诊断可见） |
| 16 | Mock 源在正式路径无条件注册 + 默认音源是 mock | 新用户可能看到 "Phase 0 Sessions" | 第 123 节；`MockSourceGatingTests` | 已修 |
| 17 | 含 `::` 的外部 ID **读不回来** | 该曲目的歌词偏移/历史静默丢失 | 第 106 节；`TrackIdentityStorageKeyTests` | 已修（只在首个 `::` 切分） |
| 18 | `-352` 风控码**不重试** | 一次失败就失败 | 第 104 节；`BiliRiskControlCodesTests` | 已修 |
| 19 | 数据被从备份恢复过却**不告诉用户** | 用户不知道少了最近改动 | 第 119/120 节；`StorageStateDiagnosticsTests` | 已修（诊断 + 设置页） |
| 20 | 音频缓存**无上限** | 磁盘无限增长 | 第 86 节；`AudioCacheTrimTests` | 已修（500MB LRU） |

## 五、配置漂移（改一处忘另一处）

| # | 对拍内容 | 证据 |
|---|---|---|
| 21 | 字符串目录 ↔ 界面字面量 | 第 92 节 |
| 22 | 设置范围 ↔ 界面滑块 | 第 130 节（**范围数字原本是我编的**） |
| 23 | 三个仓储 ↔ 权威复合键 | 第 106 节 |
| 24 | App Group ↔ 两个 entitlements | 第 143 节 |
| 25 | 深链 scheme ↔ Info.plist（含构建产物） | 第 144 节 |

### 隐私出口矩阵（详见[交接日志](archive/HANDOVER_LOG.md)第 178 节）

被动暴露类出口 6 个，全部已遮罩：完整播放器 / 胶囊 / 悬浮歌词 / 菜单栏 /
桌面小组件 / **系统正在播放**（本轮补上）。
诊断报告、日志、调试叠加层核实后不含曲目内容。

### 资源注册矩阵（详见[交接日志](archive/HANDOVER_LOG.md)第 190 节）

10 个向外注册资源的类（观察者 / 定时器 / KVO / display link / 热键 / 磁盘缓存），
全部核对过清理点；本轮补齐了 `MorphWindowController` 的观察者与刷新循环。

## 六、删掉的死代码

类型级 2 个、配置对象 1 个、设置项 1 个、方法 8 个、不可达 UI 区块约 150 行。
其中值得单独提的：**扫码登录有两份轮询实现**（一份从未被调用、语义还不同）。

## 七、验证现状

| 类别 | 结论 |
|---|---|
| 单测 | 最新条数见 [上线清单](RELEASE_CHECKLIST.md) 第一节（`check-doc-numbers` 核对它与实测一致）；B 站专属用例已随 B 站源一起移出主应用 |
| 覆盖率 | 以 [`evidence/coverage.txt`](evidence/coverage.txt) 为准，含零覆盖文件清单 |
| 零覆盖文件是否该补测 | 2026-11-16 核过当时的 6 个文件（多数是后来随 B 站源删除的视图）：只有视图组合与桥接，没有可抽出的纯逻辑，不该补测。现在清单里的 5 个文件（见 `coverage.txt`）还没有逐个重新核过 |
| 编译警告 | Release 主产物 **0**；生产代码 **0**（测试目标另有既有 Swift 6 `@MainActor` 隔离提示） |
| 架构 / 死代码闸门 | `architecture-lint`、`dead-code-scan`、`check-doc-numbers` 全通过 |
| 真机（2026-11-16） | 启动 0.63s、25MB、空闲 CPU 0.2%、90 秒无 fd/线程/内存增长 |
| 灾难恢复 | 库损坏→隔离→备份恢复、偏好写坏→正常启动（均真机演练） |
| UI 排版 | 证据图共 5 张（离屏渲染；另 11 张含个人桌面信息、商业歌曲或 B 站时代界面，开源前已移出），见 `docs/evidence/` |

## 八、如何核对这份报告

```bash
./Scripts/verify.sh                      # 单测 + 架构 + 死代码 + Release 0 警告
python3 Scripts/dead-code-scan.py        # 零引用类型
xcrun xccov view --report --json <xcresult>   # 覆盖率
ls docs/evidence/*.png                   # 排版证据图（张数见第七节）
./Scripts/check-doc-numbers.sh           # 核对本报告里的数字是否过期
```

报告里的每个数字都能用上面几条复现；对不上就是文档过期了，请以命令输出为准。

## 九、收官状态

2026-11-20 在前期 P0/P1/P2 闭环及第一、第二阶段歌词/播放体验升级的基础上，进一步完成**多音源插件化重构与外部兼容体系**：抽象通用播放缓存与 `SourceManager`，内置本地音库 / OpenSubsonic / WebDAV，剥离内置 B 站实现为独立插件 B 站外部插件（开源前已移出仓库、不再分发），并制定 [`SOURCE_SPEC.md`](SOURCE_SPEC.md) 兼容 MusicFree、LX、JSON API 模板与订阅导入，通过多仓库 GitHub 真实源实网端到端验证（详见[交接日志](archive/HANDOVER_LOG.md)第 201–215 节）。

2026-11-21 又完成一轮代码审查修复与沉浸播放模式（节拍联动、三档切换、播放页背景），见[交接文档](HANDOVER.md)第 10 节。测试与构建基线见[上线清单](RELEASE_CHECKLIST.md)。

2026-11-21 同日完成一次全量代码审计（第〇节）：P0 无、P1×10、P2×38、P3×9，逐项证据与修复顺序见 [CODE_AUDIT_2026-11-21.md](CODE_AUDIT_2026-11-21.md)；未闭环前先按 [NEXT_STEPS.md](NEXT_STEPS.md) 的优先级处理。

## 十、仍未验证（需要外部条件）

| 项 | 为什么没做 | 如何补 |
|---|---|---|
| `play()` 真跑 | 不出声约束 | `SLP_AUDIO_TEST=1` 跑 `AudioPipelineOptionalTests`（全程静音） |
| UI 自动化 2 条 | 会弹窗口 | 需要同意后执行 |
| 多显示器热插拔 | 只有一块屏 | 需要硬件 |
| VoiceOver 走查 | 需人工听读 | 需要人工 |
