# FLOW Voice — 纯原生 AI 翻唱管线

> [!IMPORTANT]
> **本轮重点修复（2026-11-22）**：
> - **音质与原声对齐**：强制校验 RVC ContentVec 特征编码器（拒绝原版 `hubert-base-ls960`）、`ONNXSineGenSanitizer` 运行时修正常量 `-0.5` 根除静音段后锁频杂音、转换前强制等待渐进流完整落盘。
> - **切播零失灵红线**：`VoicePlaybackDriver` 必须由 `AppContainer.voiceDriver` 强持有（`VoiceContainer` 内全部回调为 `[weak driver]`）；切换原曲/AI 版通过 `pendingExplicitAutoplayTrackKey` 防止竞态吞起播，切回原曲还会在插件失效时自动回退 `MediaAudioCache` 本地缓存。
> - **底栏控件防截断**：`FlowSegmentedSwitch` 保持单行不截断，窄栏自动显示「原曲 / AI」。

作为播放器的**可选本地扩展功能（初始默认关闭且不自带任何模型）**，在用户按需配置底座 ONNX 模型与导入 `.voicepack` / `.onnx` RVC 音色后，把当前歌曲人声重唱并与伴奏混回高码率 AAC `.m4a`。
整条链路 **100% 运行在原生 Swift 进程内**（`OnnxRuntime.xcframework` + `CoreML` / `CPU EP` + `AVFoundation` + `Accelerate/vDSP`），已彻底移除 Python 运行时与子进程依赖；初始未配置模型或功能关闭时切歌与播放完全静默无侵入。

## 1. 原生推理链路

```text
原曲 ──▶ AVFoundation 解码 ──▶ MDX-Net ONNX 人声分离 (vDSP STFT/ISTFT)
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                               ▼
         人声 (16kHz + 48Hz 高通)                               伴奏
                 │
                 ├──▶ Mel (vDSP) + rmvpe.onnx ──▶ F0 移调与量化
                 ├──▶ hubert_base.onnx + index.f32bin (vDSP_mmul k-NN)
                 ▼
         音色 model.onnx (动态 T) + 响度包络融合 (RMS)
                 │
                 └───────────────▶ 与伴奏混音限幅 ──▶ AAC .m4a (256kbps)
```

每一步均对应独立磁盘缓存键，参数或音色变化只失效受影响层级：

| 层级 | 目录 | 键 |
|---|---|---|
| 一级（分离） | `Voice/separation/` | `sep-{pipelineVersion}-{sha256前16}`（`.vocals.wav` + `.inst.wav`） |
| 二级（合成） | `Voice/conversion/` | `vc-{pipelineVersion}-{sha256前16}`（`.vocals.wav`） |
| 三级（成品） | `Voice/renders/` + `manifests/` | `render-{pipelineVersion}-{sha256前16}`（`.m4a` + manifest） |

`pipelineVersion = 3`（定义在 `VoiceCacheManager`）；默认总缓存上限 8 GB，每次落盘后自动触发 `enforceCapacity()`：先按 LRU 回收可重建的分离/合成中间文件，仍超限才回收最旧的成品。
数据目录位于 `~/Library/Application Support/FLOW/Voice/`。

- **只在显式操作时生成**：切歌、搜索播放、原曲缓冲落盘都只刷新"已有成品是否命中"，从不自动入队；生成入口只有播放器「音色」面板/版本切换里的「生成并播放 AI 版」「重新生成」。AI 总开关的含义是"有成品时优先播 AI 版"。
- **离线页管理成品**：manifest 额外保存 `track`、`packName`、`separationKey`、`conversionKey`（早期 manifest 没有，读出为 nil，离线页按身份从离线库/曲目库反查歌名）。离线页「AI 翻唱」分页按"同曲 + 同音色"列最新一份，可播放、在访达中显示、逐条删除或清空；删除会连带清掉只被它引用的中间文件，早期 manifest 无法对应时在全部成品删完后统一清扫（有转换任务在跑时不扫）。从离线页点播会钉住该成品，不受当前所选音色/参数与底座模型影响；切换音色或调参后钉住失效。

## 2. 代码地图

```text
Vendor/OnnxRuntime/
  OnnxRuntime.xcframework               ONNX Runtime 1.32.0 动态库 + C API 头文件（MIT）
Tools/rvc-converter/
  convert_to_voicepack.py               离线转换工具：RVC .pth + .index -> .voicepack (.onnx + .f32bin)
  export_base_models.py                 离线导出工具：导出 rmvpe.onnx 与双输出 hubert_base.onnx
Voice/
  Runtime/ORTSession.swift              ONNX Runtime C API 包装 + RunOptionsSetTerminate 取消 + CoreML 运行时回退
  Audio/VoiceAudioDSP.swift             AVAudioFile 解码/重采样/M4A+WAV 写入 + vDSP STFT/ISTFT/Mel/Butterworth/RMS
  Models/MDXModelCatalog.swift          UVR MDX-Net 44 组已知模型末尾 10MB MD5 参数查找表
  Models/MDXVocalSeparator.swift        UVR MDX-Net 分离（支持 .best 双次反相降噪）
  Models/RMVPEPitchExtractor.swift      RMVPE ONNX F0 提取与移调/中值滤波/梅尔量化
  Models/F32VectorIndex.swift           .f32bin 紧凑浮点索引加载与 vDSP_mmul k=8 加权检索
  Models/HuBERTFeatureExtractor.swift   HuBERT ONNX 特征提取（兼容 v2 768 维与 v1 256 维）
  Models/ONNXSineGenSanitizer.swift     运行时修复 RVC ONNX SineGen Float32 静音相位漂移阈值
  Models/RVCVoiceConverter.swift        分段零过零切分、清辅音保护与 RVC ONNX 合成主链
  Models/VoiceModelAssetsManager.swift  Models/ 基础模型状态管理、ContentVec 兼容性校验与联网受控下载
  Models/VoiceModelDiscovery.swift      HuggingFace（经默认镜像）/ GitHub RVC 模型检索、精选音色与直链分类
  Models/VoiceModelMirror.swift         镜像模式与候选地址（文件下载/检索 API 分开）、受控大文件下载与流式 SHA256
  Models/OnlineVoiceCatalog.swift       「精选」可下载卡片的内置种子、自动获取合并、英文名整理与中文译名缓存
  Models/CuratedVoiceCatalog.swift      需先转换的角色卡片与 ~/Downloads/FLOW-VoicePacks 检测
  Model/VoiceTypes.swift                音色包、版本、参数、任务状态、错误类型
  Engine/VoiceEngineAdapter.swift       引擎注册表（默认自动注册 RVCEngineAdapter）
  Engine/RVCEngineAdapter.swift         通过 ORTSession 计算图自检 .voicepack/.onnx，明确拒绝 .pth
  Backend/VoiceInferenceBackend.swift   CoreMLONNXBackend + CPUONNXBackend（真实探针）
  Cache/VoiceCacheManager.swift         三级磁盘缓存、无源缓存回退查找与 LRU 容量回收
  Pack/VoicePackStore.swift             .voicepack/.onnx 导入（失败回滚）、多版本切换、重命名、删除
  Preset/VoicePresetStore.swift         内置与自定义风格预设
  Task/VoiceTaskManager.swift           纯 Swift 异步任务队列、输入音频完整性校验与真可取消推理
  Integration/VoiceContainer.swift      容器装配（由 `AppContainer.voiceDriver` 强持有防弱引用悬空）、音频流落盘联动与 PlaybackCoordinator 预热/切版隔离
  Integration/VoiceManager.swift        @Observable UI/业务门面，参数调节防抖落盘、版本切换与选装卸载管理
  Integration/VoicePlaybackDriver.swift 播放会话工厂、原曲↔AI 版本无中断热切换（防并发竞态吞起播）、成品被删时退回原曲
UI/Voice/
  VoiceImportHelper.swift               共用的 Sandbox 导入/拖拽导入修饰符与音色包封面头像组件
  VoiceVersionSwitch.swift              播放控制栏与沉浸胶囊共用的「原曲 / AI 翻唱」切换胶囊（窄栏自适应防截断）
  VoiceModelFetchSheet.swift            社区音色精选、HuggingFace/GitHub 在线检索与直链自动导入面板
  VoiceControl.swift                    播放栏及沉浸胶囊 32pt 图标 + 版本切换/播放/取消/强制重生成/拖拽导入/直达设置面板
  VoiceAdvancedPanel.swift              音色包多版本切换、拖拽导入、参数滑杆与预设管理面板
UI/Settings/
  SettingsView.swift                    设置页 `VoicePane`：选装开关、播放栏入口显隐、版本切换/删除、拖拽导入、底座模型单项移除与一键完全卸载
```

## 3. 安全模型格式与离线转换

为了消除运行时任意 pickle 反序列化风险与应用体积膨胀，App 本身**不打包 Python 解释器**，也不直接读取 `.pth` / `.index`。
社区下载的模型可使用仓库自带的离线脚本转换：

```bash
python3 Tools/rvc-converter/convert_to_voicepack.py \
  --pth /path/to/singer.pth \
  --index /path/to/singer.index \
  --name "Singer" \
  --output ./out
```

生成安全目录 `<name>.voicepack/`：
- `pack.json`：模型架构（`v1`/`v2`）、`hasF0`、目标采样率、`embeddingDim`、SHA256
- `model.onnx`：动态时间维 `T` ONNX 合成计算图（输入显式接收 `rnd`）
- `index.f32bin`：（可选）16 字节定长头 `F32I` + 原始 `float32` 检索矩阵

转换环境实测（2026-11-22，Python 3.13 venv）：`torch 2.15.0`、`onnx 1.23.2`、`onnxruntime 1.32.0`、`scipy 1.18.1`、`faiss-cpu`。缺少任一依赖时脚本会直接 ImportError，需先安装：

```bash
python3 -m venv ~/flow-rvc-venv
~/flow-rvc-venv/bin/pip install torch onnx onnxruntime numpy scipy faiss-cpu transformers
```

基础底座模型位于 `~/Library/Application Support/FLOW/Voice/Models/`：
- `rmvpe.onnx`、`hubert_base.onnx`（ContentVec 768-dim）与 `UVR-MDX-NET-Voc_FT.onnx`：设置页「一键补齐缺失模型」（可取消），或首次生成时由任务自动下载（2026-11-23 起缺模型但允许联网时不再拦在入口，生成面板会显示下载进度）；内置官方 SHA256 校验，按「镜像 → 官方」回退（hubert 只有一个源）。也可在设置页手动导入；`Tools/rvc-converter/export_base_models.py` 只能导出 rmvpe 与 hubert。目前只有模拟网络的单元测试，三个底座的实网整链下载尚无证据。
- **播 AI 成品的前提**：AI 开关打开，且底座模型齐备；例外是从离线页点播的成品（已钉住，播成品不需要模型）。

## 3.1 精选音色卡片

在线获取面板默认显示「精选」页签，分两部分（2026-11-23 起）：

**可直接下载（自动获取）**：内置 11 个核实过 SHA256 的可运行音色（`OnlineVoiceCatalog.seeds`，来自 `ozada/onnx_rvc`、`DogManTC/test-rvc-onnx`）作为兜底——国内连不上 huggingface.co 的检索接口时卡片照样显示，下载走 `/resolve/` 镜像；联网时打开面板会在后台用「rvc onnx」「voicepack」检索补充新出现的音色（最多读 6 个仓库详情）。卡片名先由 `VoiceNameLocalizer` 把文件名整理成英文名（`GuraTalkV2` → `Gura Talk V2`），通用词直接查表（`woman_1` → 女声 1），人名交给系统翻译（macOS 15+ `Translation`，首次会询问是否下载语言包，拒绝则保持英文并留「翻译成中文」按钮），译名缓存在 `Voice/name-translations.json`。下载导入时用中文名作音色名；按模型文件 SHA256 识别已导入，用户改名后仍显示「已导入 / 使用」。

**角色音色（需先在电脑上转换）**：卡片使用中文名与出处作品，目前包含：

| 卡片 | 出处 | 公开源 | 转换后文件夹 |
|---|---|---|---|
| 高松灯 | BanG Dream! It's MyGO!!!!! | `TogetsuDo/tomori-rvc` | `高松灯.voicepack` |
| 曼波小马 | 赛马娘 Pretty Derby | `juzi45/RVC_Matikanetannhauser` | `曼波小马.voicepack` |
| 千早爱音 | BanG Dream! It's MyGO!!!!! | `TogetsuDo/anon-rvc` | `千早爱音.voicepack` |

这三个角色的公开源都只提供 `.pth`（+ `.index`），App 不能直接运行。用桌面转换工具把生成的 `.voicepack` 放到 `~/Downloads/FLOW-VoicePacks/` 后，卡片会显示「导入」，点一下即可写入音色库并以中文名出现在播放页；已导入的卡片显示「已导入」标签和「使用」按钮。没有转换包时卡片显示「尚未转换」并提供源站链接，不会假装可下载。

检索框直接输入中文名或罗马字（`高松灯`、`tomori`、`小马曼波`、`tannhauser`、`千早爱音`、`anon`）会精确映射到对应仓库。其他音色仍在 HuggingFace / GitHub / URL 直链页签按原样检索。

> 沙盒构建靠 `com.apple.security.files.downloads.read-only` 读取该目录，路径按真实用户主目录计算（沙盒里 `homeDirectoryForCurrentUser` 指向容器）。签名沙盒包里的实际读取仍待验证；读不到时仍可用「导入音色」手动选择文件夹。

## 4. 在线模型获取、直连自动导入与默认镜像源

- **下载通道**：默认 `hf-mirror.com`，在「设置 → 音色 → 模型下载与镜像源」可切换「默认镜像源」「官方直连」「自定义镜像（HF 域名可带子路径，另可设 GitHub 加速前缀）」；模型文件失败时自动回退官方地址。
- **检索 API 与镜像的分工**：`hf-mirror.com` 只代理文件下载，`/api/*` 会 308 跳回 `huggingface.co`。所以默认镜像与官方模式下检索**直接请求官方 API**（`VoiceModelMirrorConfig.apiCandidateURLs`，不再白等一轮镜像超时）；自定义镜像可能代理了 API，先试镜像再回退。连不上时提示「镜像只能加速下载，可以在 URL 直链里粘贴下载链接」。2026-11-23 实网用例：关键词检索约 1.7 s、仓库详情约 0.8 s 通过（`testLiveHFKeywordSearchReturnsRepos` / `testLiveHFMirrorDiscoveryAndInspect`）。
- **社区模型发现与一键导入**：`VoiceModelDiscovery` 在 HuggingFace 与 GitHub 公开仓库中检索可直接运行的音色：独立 `.onnx`（排除 `rmvpe`/`hubert`/`uvr` 等底座文件名，自动配对同名 `.f32bin`），以及仓库里的 `xx.voicepack/` 文件夹（`pack.json` / `model.onnx` / `index.f32bin` / 封面整组下载后按文件夹导入）。HF 文件按 `lfs.sha256` 校验；GitHub 无哈希可校验。GitHub 被限流（403/429）时如实提示，不再显示成「仓库暂无文件」。
- **下载即导入**：`VoiceModelFetchSheet` 支持关键词搜索、`owner/repo` 直达、或粘贴 HuggingFace/GitHub 文件链接（`/blob/` 网页链接、HF 数据集链接自动纠偏）；下载完成后直接写入 `VoicePackStore`。下载可随时取消（行内 ✕），卸载组件、关闭「允许联网」也会取消进行中的下载；同一音色重复点击不会重复下载。面板默认停在「精选」，切到 HF / GitHub 页签时自动检索一次；切换页签会取消上一页签的检索，结果不会串到别的页签。
- **直链分类**（`VoiceModelDiscovery.classifyDirectLink`）：`.onnx` 直接下载（只给 HF `/resolve/` 的 `.onnx` 时自动尝试同名 `.f32bin`）；仓库页面或 `.voicepack` 文件夹链接切换到仓库检索；`.pth` / `.index` 提示需先转换，`.zip` 等压缩包提示先解压再拖入，避免下载数百 MB 后只得到一句看不懂的格式错误。
- **结果可读性**：检索只返回**确实含可运行音色**的仓库；每个仓库摘要直接列出前三个音色名（如「12 个音色：beyonce、luna v2、… · 1200 次下载」）。
- **运行时 ONNX 兼容与真机稳定性保障（2026-11-22 闭环）**：
  - **特征编码器识别**：`HuBERTFeatureExtractor` 自动适配带/不带布尔型 `padding_mask` 的社区 ONNX；`RMVPEPitchExtractor` 同时兼容 `[B, 128, T]` 梅尔谱与 `[B, L]` 波形输入以及 `salience` / F0 输出；`VoiceModelAssetsManager` 自动拦截/提示重下误装的原版 `hubert-base-ls960`（确保使用真 RVC ContentVec 编码器）；
  - **SineGen 相位净化**：`ONNXSineGenSanitizer` 运行时自动将 `.onnx` 中 `SineGen` 的 `< 0.0` 相位阈值常量修正为 `-0.5`（APFS CoW 克隆），根除静音段后浮点误差漂移引发的量化锁频杂音（真机实测 `hubert_base.onnx` + `高松灯` `.m4a` 生成通过）；
  - **原曲缓存等待与播放协同**：`VoiceManager.inputEnsurer` 通过 `OfflineLibraryManager.ensureCachedAudioFileURL` 等待在途流完整落盘或拉取完整原声后再启动转换（避免半首杂音/不完整输入），并通过 `AppContainer.voiceDriver` 随主容器强持有至销毁，保证 `VoiceContainer` 中 `[weak driver]` 回调长期有效；
  - **原曲↔AI 双向热切防竞态与本地兜底**：`VoicePlaybackDriver` 协调 `onVoiceContextChanged` 与显式按钮点击（`pendingExplicitAutoplayTrackKey` 防止 `.paused`/`.ready` 起播被并发重载吞掉）；切回原曲时即使在线 JS 插件短暂失败或历史曲目恢复欠缺，[`PlaybackCoordinator`](../Playback/PlaybackCoordinator.swift) 仍可自动兜底复用 `MediaAudioCache` 已有完整缓存，同时 `FlowSegmentedSwitch` 禁止底栏分段标题压缩为 `...`。
