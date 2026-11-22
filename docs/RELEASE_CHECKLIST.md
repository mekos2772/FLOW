# 上线前检查清单

> 记录基线：2026-11-16 初次评审，2026-11-20 更新多音源插件化重构，2026-11-21 更新代码审查修复与沉浸播放模式，**2026-11-22 更新自动获取音源与预设收拢、FLOW Voice 模型/音色自动获取与默认镜像、降门槛改造、ContentVec/SineGen 相位缺陷根治、`AppContainer.voiceDriver` 强持有、JS 插件历史元数据持久化与切原曲本地缓存兜底修复及最新构建 / 单测结果**。每项都注明**证据来源**，
> 便于区分"已验证"与"仅推理"。表里的"第 N 节"指 [交接日志](archive/HANDOVER_LOG.md)。
>
> **测试条数只写在本页第一节**：`Scripts/check-doc-numbers.sh` 会拿它和最近一次 `verify.sh` 的实测比对，其他文档一律链接到这里。

## 当前发布判断（2026-11-23）

**分发方式：开源（MIT），GitHub Releases 发 DMG，不上 App Store、不做付费签名。**
工程门禁通过（1312 条单测 / 0 失败、Release 0 警告），可以按开源 Beta 发布。

- 安装包用 ad-hoc 签名（带沙盒权限），用户首次打开要右键「打开」——README「安装」一节已写明。ad-hoc 下不能开 Hardened Runtime（会拒载同为 ad-hoc 的 OnnxRuntime）。
- 没有 Team ID 时 App Group `group.com.yg.spatiallyrics` 无法正式授权，桌面小组件可能读不到播放状态（应用已按"不可用"兜底，诊断里如实显示）；以后要做 Developer ID 签名再改成 `<TeamID>.group…`。
- 公开仓库：`~/FLOW-public`（单个首个提交，606 个文件，未推送；按 `.gitignore` 从本目录导出）。开源准备（2026-11-23）：MIT `LICENSE`、[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)（ONNX Runtime 许可 + ThirdPartyNotices 已打进应用，关于页可查看）、`Tools/rvc-converter/rvc_models/NOTICE.md`；ONNX Runtime 二进制不进仓库，由 `Scripts/fetch-onnxruntime.sh` 从微软官方 PyPI 包取回并双重校验 SHA-256；B 站抓取插件、一键预设与指向抓取类音源的搜索快捷词已移出公开仓库；公开仓库从干净的首个提交开始（旧历史里的截图含个人信息）。
- 2026-11-23 功能收尾：新手引导（文字 + 箭头，首次打开自动显示、可跳过、设置里可重看）；AI 版「生成并播放」在需要先生成时不再丢失自动播放；预热下一首不再覆盖当前会话追踪；有转换在跑时不清理缓存、删成品不动中间文件；导入「自动音质」备份后运行时同步回自动；小组件显示名统一为 FLOW。
- **安装包**：`./Scripts/package-release.sh` 一键生成 `dist/FLOW-<版本>-arm64.dmg`（ad-hoc 签名 + 沙盒权限 + 两个 ONNX 许可文件，SHA-256 `56c3a99c…72bc`）。同一份源码的包已在本机冷启动实测（引导逐级出现、看过后保存、设置里可重看），见 [`evidence/release-2026-11-23.txt`](evidence/release-2026-11-23.txt)。发布时上传到 GitHub Releases。
- 仍未验证：干净机器上的首次安装、FLOW Voice 全曲人工试听、沙盒包读 `~/Downloads/FLOW-VoicePacks`、三个底座模型实网整链下载；第三方 JS 同步死循环等其余审计项见 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)。

> [!IMPORTANT]
> **本轮核心突破（2026-11-22 晚）**：真机打通 FLOW Voice「原声完整缓冲 → ContentVec + SineGen 净化推理 → 点击播放 AI 版 → 切回原曲不断源」完整闭环（`AppContainer.voiceDriver` 持活 + JS 插件历史 `bvid` 修复 + 切原曲本地缓存兜底 + `hdslb.com` ATS 修复 + 底栏胶囊防截断）。

- 已实现此前十项 P1 修复；本轮补齐播放 P2-1…P2-8、跨源请求头 P2-14 与 HLS 子请求策略。
- HLS 使用仅监听 `127.0.0.1` 的会话代理，路由有 HMAC 认证；主/子列表、分片、初始化片段、密钥和重定向逐跳校验，动态检查联网开关。真实 AVPlayer 已静音起播并验证位置推进。
- `PlaybackReleaseTests` 通过可控挂起复现切歌/停止/取消/旧回调竞态；`HLSResourceTests` 覆盖真实 HTTP、拒绝越域、路由篡改、大小限制、联网门控和播放。

## 一、已验证（有可复现证据）

| 项 | 结论 | 证据 |
|---|---|---|
| 编译警告 | Release 0 警告 | 本轮全量 `./Scripts/verify.sh`（2026-11-23，干净 derivedData） |
| 强制解包 / 崩溃点 | 业务逻辑 0 处（仅 `MTKView required init(coder:)` 与兜底内存库 `preconditionFailure` 各 1 处；`ORTSession` 已改为抛出错误） | `grep "try!\|as! \|fatalError"` |
| 单元测试 | **1312 条**、9 跳过、0 失败 | 全量 `./Scripts/verify.sh`（2026-11-23 01:43 干净重跑；开源整理移走 B 站插件端到端用例 2 条，无测试进程崩溃/重启；新增新手引导几何与渲染、AI 版生成并播放意图、预热追踪、转换中拒绝清缓存等回归；此前 2026-11-22，FLOW Voice ContentVec/SineGen 杂音与原曲↔AI 切换联动、`AppContainer.voiceDriver` 持活、JS 插件元数据持久化与切原曲缓存兜底修复；AI 翻唱不再随切歌自动生成、离线页管理 AI 成品；2026-11-23 设置页审查修复、音色获取修复、精选卡片自动获取/翻译、本地化门禁扩到自定义组件及回归测试） |
| 代码覆盖率 | 见 [`evidence/coverage.txt`](evidence/coverage.txt)（唯一权威来源） | 同次全量单测 `xcrun xccov`，2026-11-23 01:43 |
| 真实 HLS 播放与策略 | 回环 HTTP + AVPlayer 静音播放、进度推进；域名/重定向/密钥/大小/路由/联网开关回归通过 | `HLSResourceTests`（全量默认执行） |
| 真实本地音频 play / pause | 真实播放时钟推进，暂停后时钟冻结，全程静音 | `TEST_RUNNER_SLP_AUDIO_TEST=1`，`AudioPipelineOptionalTests`，2026-11-22 17:00 |
| 联网发布专项 | 15 条通过、0 跳过、0 失败；另 LRCLIB 1 条通过、0 跳过、0 失败 | 多源搜播/HLS + GitHub 发现 + HF 镜像检索 + 真实音频；见 [`evidence/release-2026-11-22.txt`](evidence/release-2026-11-22.txt) |
| 启动 / 退出 | 1 进程 1 窗口；退出后归 0 | 真机冒烟（第 94 节） |
| 空闲资源 | CPU 0–0.8%，RSS 133MB 恒定 40s | `ps` 采样 |
| 数据库备份 | 打开/退出各写一份，保留 3 份；`backUpStoreNow` 绑定实例路径 | 目录实测 + `StoreBackupTests` + `ReviewRegressionTests` |
| 崩溃恢复 | 隔离损坏库 → 从备份恢复成功 | `StoreBackupTests` 端到端 |
| 音频缓存上限 | 500MB，最旧优先淘汰 | `MediaAudioCacheTrimTests` |
| 日志脱敏 | 查询串/路径/长令牌均处理，host 保留 | `LoggingCoverageTests` |
| 本地化 | **1055 条双语键**（2026-11-23，每条都有 en 与 zh-Hans），en/zh-Hans 全覆盖（含沉浸模式、三档切换与背景，含首页一键开箱/全局拖放导入、无歌词快捷搜词与本地导入、GitHub jsDelivr CDN 回退、多音源配置/设置页自动获取与扩展预设/GitHub 自动搜索发现/导入/插件参数编辑、本地文件夹权限、音效/EQ、双语译文与手动搜词绑定、FLOW Voice 原生音色管理/RVC 模型在线检索/下载直连自动导入/默认镜像源/三底座全量自动获取/ContentVec 与原曲↔AI 版本切换交互/拖拽导入/完全卸载/MIT 开源声明与错误文案） | `LocalizationCoverageTests` + `InterpolatedStringLocalizationTests` + `ReviewRegressionTests` |
| 歌词简体归一 | 繁→简全链路覆盖（`TextNormalizer`、`LRCParser`、`AMLL`、`LRCLIB`、插件字幕与本地侧车 LRC），日文保留 | `TextNormalizerTests` + `LyricsRegressionTests` + `ReviewRegressionTests` |
| Widget 隐私 | 脱敏与未确认隐藏曲目不泄露，未确认不报播放中 | `WidgetSnapshotTests` + `ReviewRegressionTests` |
| Widget 刷新 | 换歌立刻、进度最多 30 秒一次 | `WidgetReloadThrottleTests` |
| 沙盒 / App Group | entitlement 与代码常量一致；移除过期音频文档类型 | `Config/*.entitlements` + `App-Info.plist` |
| 启动到窗口 | **0.63s**（Release，热启动） | `open` + 轮询窗口列表 |
| 包体积 | **61M**（主程序 `27M` + `OnnxRuntime.framework` `33M` + 小组件 `428K`，2026-11-23 Release） | `du -sh .app` |
| 空闲资源 | CPU 0.2%，RSS 139MB | `ps` 采样 |
| 空闲 90 秒稳定性 | fd 68→64、线程 10→7、RSS 134MB（无增长） | `lsof` / `ps -M` 采样 |
| 运行期日志 | SwiftUI 视图更新告警 0 条、自身错误日志 0 条 | `log stream --predicate 'process == "SpatialLyricsPlayer"'` |
| 死代码 | 零引用类型 0 个 | `python3 Scripts/dead-code-scan.py` |
| FLOW Voice 原生端到端转换、切歌切换与真机修复 | 真机 `rmvpe.onnx` + `hubert_base.onnx` (ContentVec) + `高松灯` 生成 `44.1kHz .m4a`，`AppContainer.voiceDriver` 强持有 + `ONNXSineGenSanitizer` 相位修正 + 原曲↔AI 热切及缓存兜底均通过 | `VoicePipelineIntegrationTests` + `PluginImporterTests` + 2026-11-22 真机实测 |
| FLOW Voice 取消与播放协调 | `OrtApi::RunOptionsSetTerminate` + `Task.checkCancellation()` 立即取消；离线无源 AI 起播与 Gapless `prewarm` 通过 | `VoicePipelineIntegrationTests`（2026-11-21 – 11-22） |
| ONNX Runtime 核心封装 | `OnnxRuntime.xcframework`（1.32.0，CoreML + CPU EP）实测动态输入维度推理与 `vDSP` 混合基数 STFT/ISTFT 往返 `< 1e-4` | `ORTSessionAndBackendTests` + `VoiceAudioDSPAndPackTests` |

## 二、仅逻辑验证（未真机）

| 项 | 风险 | 如何补验 |
|---|---|---|
| 有声主观听感与输出设备切换 | 中：真实 `play()` 位置推进/暂停冻结已静音实测；有声听感、物理耳机拔插仍未做 | 最终签名安装包人工试听与硬件操作 |
| UI 自动化（两条冒烟） | 低：已修正，未执行 |
| 多显示器热插拔 | 中：只有一块屏 |
| 真实全屏应用隐匿 | 中：AX 读不到全屏状态 |
| VoiceOver 人工走查 | 低：标注已做，未实测 |
| FLOW Voice 多曲风分离与 `v1`/`32k`/`48k` 广度试听 | 中：已完成单套 `hubert_base.onnx` + `高松灯` 真机全曲合成与原曲↔AI 切换实测；更多曲风高动态伴奏与 `v1/32k/48k` 社区音色尚缺广度试听 | 在真机导入更多曲风与 `v1/v2` `.voicepack` 对比试听 |
| FLOW Voice 音色面板辅助功能与最终包首次安装走查 | 低：核心开关/播放/原曲↔AI 切换已在 Release 实机验证，仍缺无障碍读屏与正式签名包首次使用走查 | 正式签名安装包补充完整交互与 VoiceOver 走查 |

## 三、审阅中发现并已修的问题（摘要）

详见[交接日志](archive/HANDOVER_LOG.md)第 60–98 节，其中影响最大的是：

1. **测试在写使用者真实数据库**（第 85 节）——`PersistenceController` 忽略注入路径，
   这是早先"收藏被清空"的真正原因；
2. **用 `bgm_info` 当过滤信号会删掉 75% 真歌**（第 81 节）——假设未经验证；
3. **Widget 每秒重载**会被系统限流导致停止更新（第 98 节）；
4. **UI 冒烟测试断言的是早已删除的骨架文案**，且会碰真实库（第 96 节）；
5. **时长显示漏了小时位**（第 90 节）。

## 四、复现命令

```bash
# 全量单测（离线可复现）
xcodebuild test -workspace SpatialLyricsPlayer.xcworkspace -scheme SpatialLyricsPlayer \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/slp-dd \
  -only-testing:SpatialLyricsPlayerTests CODE_SIGNING_ALLOWED=NO

# 覆盖率
xcodebuild test ... -enableCodeCoverage YES
xcrun xccov view --report --json <xcresult>

# 一键验证（推荐：上线前跑这一条）
./Scripts/verify.sh

# 发布前可选运行联网集成测试（LRCLIB 与 GitHub/开放源多配置实网端到端检查）
./Scripts/verify.sh --live
TEST_RUNNER_SLP_LIVE_TEST=1 SLP_LIVE_TEST=1 xcodebuild test \
  -workspace SpatialLyricsPlayer.xcworkspace -scheme SpatialLyricsPlayer \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/slp-dd \
  -only-testing:SpatialLyricsPlayerTests/MultiConfigCompatTests CODE_SIGNING_ALLOWED=NO

# 架构约束
./Scripts/architecture-lint.sh

# 死代码（零引用类型）
python3 Scripts/dead-code-scan.py
```

## 五、发布前的"必跑但默认不做"项

| 项 | 为什么默认不做 | 发布前怎么做 |
|---|---|---|
| 联网集成测试 | 需要网络，会让常规 CI 变慢变脆 | `./Scripts/verify.sh --live` 与 `TEST_RUNNER_SLP_LIVE_TEST=1 SLP_LIVE_TEST=1 ... -only-testing:.../MultiConfigCompatTests`（已实测 12 条 0 失败） |
| `play()` 真跑 | 常规默认跳过 | 本轮已用 `TEST_RUNNER_SLP_AUDIO_TEST=1` 实测，通过真实音频时钟推进与暂停冻结（全程静音） |
| UI 自动化 2 条 | 会弹窗口 | 手动执行 `SpatialLyricsPlayerUITests` |

这三项的共同点：**默认跳过，但跳过不等于不用做**。
发布前少做一项，就等于把对应风险留给用户。

## 六、一个已知限制：Release 配置下不能跑测试

```
xcodebuild test -configuration Release …
→ Unable to resolve Swift module dependency to a compatible module: 'SpatialLyricsPlayer'
```

原因：测试用 `@testable import`，需要 app 模块带 testability，
而 Release 默认 `ENABLE_TESTABILITY = NO`（也不该打开——那会往发布产物里塞测试钩子）。

所以分工是：

| 配置 | 跑什么 |
|---|---|
| Debug | 全量单元测试 |
| Release | 只编译 + 0 警告门禁（`verify.sh` 第 4 步） |

要在 Release 下验证运行时，用 Release 产物做手动冒烟（第 134 节的资源数据就是这么来的）。

## 七、测试套件稳定性

测试条数的演变（均为 8 跳过、0 失败，当前数字以第一节为准）：2026-11-20 多音源插件化与 `FLOW Source Spec v1` 收官时 `1041` 条 → 2026-11-21 代码审查修复后 `1078` 条 → 加入沉浸播放模式后 `1133` 条 → 加入节拍联动、三档切换与播放页背景后 `1167` 条。早期 B 站单体阶段曾连跑 4 遍 1039 条，波动约 4%。

联网用例：`SLP_LIVE_TEST=1` 下 `MultiConfigCompatTests` 实测 **12 条全通**（0 跳过、0 失败），覆盖 Navidrome / 猫耳 FM / 歌词网 / CCTV 听音 HLS / Audiomack OAuth1 / Audius / RadioBrowser / Internet Archive。
新加时序相关代码后，仍建议至少连跑 3 遍确认无竞态。
