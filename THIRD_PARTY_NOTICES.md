# 第三方组件与致谢

FLOW 本身以 [MIT 许可](LICENSE) 开源。下面列出随应用分发或在源码里使用的第三方内容。

## 随应用分发

### ONNX Runtime 1.32.0（Microsoft，MIT）

FLOW Voice（AI 翻唱）的本地模型推理。二进制取自微软在 PyPI 发布的官方 `onnxruntime` 1.32.0 wheel（macOS 14 / arm64），
只改了 install name 并做 ad-hoc 签名，获取方式见 [`Scripts/fetch-onnxruntime.sh`](Scripts/fetch-onnxruntime.sh)（带 SHA-256 校验）。

- 许可：[`Vendor/OnnxRuntime/LICENSE.txt`](Vendor/OnnxRuntime/LICENSE.txt)
- 其静态链接的第三方组件（protobuf、abseil、onnx、flatbuffers、re2、Eigen 等）的声明：[`Vendor/OnnxRuntime/ThirdPartyNotices.txt`](Vendor/OnnxRuntime/ThirdPartyNotices.txt)
- 两份文件都打进了应用（`Resources/Licenses/`），可在「设置 → 关于 → 致谢与许可」里打开。
- 上游源码：https://github.com/microsoft/onnxruntime （v1.32.0）

### Apple 系统框架

SwiftUI、AppKit、AVFoundation、SwiftData、JavaScriptCore、CoreML、Accelerate、Translation 等均为 macOS 系统自带，不随应用分发。

## 仅在源码中（不打进应用）

### `Tools/rvc-converter/rvc_models/`

离线把社区 RVC 模型转换为 `.voicepack` 的工具所用的模型定义，来自 RVC、VITS、Neural Spline Flows（MIT）与 RMVPE（Apache-2.0），有改动。
详见 [`Tools/rvc-converter/rvc_models/NOTICE.md`](Tools/rvc-converter/rvc_models/NOTICE.md)。

### 着色器里的整数哈希

`UI/Immersive/ImmersiveShaderSource.swift` 的 `hashu` 使用的常数与写法参考 David Hoskins 的「Hash without Sine」。

## 运行时从网络获取（不随应用分发）

- **AI 音色与底座模型**（RMVPE、HuBERT/ContentVec、MDX 分离模型、社区 RVC 音色）：用户在应用里主动下载，来自 Hugging Face / GitHub 上各自的发布者，许可与使用限制以原发布页为准。
- **歌词**：AMLL TTML 歌词库（CC0）、LRCLIB 等公共歌词服务。
- **第三方音源插件 / 模板**：由用户自行导入，FLOW 不收录、不分发抓取商业平台的脚本。

## 使用须知

- 内置的「精选」音色卡片只是指向第三方公开发布的模型。其中部分模型模仿真实人物或动漫角色（及其声优）的声音；
  这些声音的人格权、著作权归各自权利人所有，**下载与使用的合法性由用户自行负责**，请勿用于冒充他人、商业用途或任何侵权场景。
- 通过音源插件播放的内容，版权归各自权利人所有，请只使用你有权访问的来源。
