# FLOW Voice 离线音色转换工具（`rvc-converter`）

`SpatialLyricsPlayer` 已完全重构为 **纯原生 Swift + ONNX Runtime + Accelerate** 推理架构，应用自身**不包含 Python 运行时，也不会在运行期解析或反序列化 `.pth` / pickle 文件**。

社区下载的 RVC 模型（`.pth` + 可选 `.index`）在导入应用前，需先通过本工具离线转换为安全的 `.voicepack` 目录。

## 输出格式：`.voicepack`

```text
MyVoice.voicepack/
├── pack.json       # 模型元数据（architecture/hasF0/sampleRate/embeddingDim/sha256）
├── model.onnx      # 动态长度合成器 ONNX 计算图
└── index.f32bin    # （可选）从 FAISS .index 提取的 float32 连续矩阵，16 字节头 + 原始向量
```

应用内支持直接导入 `.voicepack` 文件夹，或单独导入 `.onnx` + `.f32bin` 文件。

## 安装依赖（仅离线转换需要）

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install torch onnx onnxruntime transformers numpy scipy faiss-cpu librosa
```

## 1. 转换 RVC 音色为 `.voicepack`

```bash
python3 Tools/rvc-converter/convert_to_voicepack.py \
  --pth ~/Downloads/speaker.pth \
  --index ~/Downloads/speaker.index \
  --name "我的音色" \
  --output ~/Downloads/VoicePacks
```

工具会自动兼容以下常见 RVC 权重：
- RVC `v1`（256 维）与 `v2`（768 维）
- `f0` 与 `nono` 无音高模型
- 完整训练 checkpoint（含 `config`）与官方/社区裸权重文件（无 `config` 自动反推）
- 导出时自动保持序列时间维动态可变，并在转换后用 ONNX Runtime 执行 `T=10/37/135` 多长度自检。

## 2. 导出基础底座 ONNX 模型

```bash
python3 Tools/rvc-converter/export_base_models.py \
  --rmvpe-pt path/to/rmvpe.pt \
  --hubert-pt path/to/hubert_base.pt \
  --output-dir "$HOME/Library/Application Support/FLOW/Voice/Models"
```

输出文件：
- `rmvpe.onnx`：F0 音高提取网络
- `hubert_base.onnx`：双输出语音内容特征网络（同时兼容 v2 768 维与 v1 256 维）

## 第三方代码

`rvc_models/` 里的模型定义来自 RVC / VITS / nsf（MIT）与 RMVPE（Apache-2.0），有改动，详见 [`rvc_models/NOTICE.md`](rvc_models/NOTICE.md)。这些代码只用于离线转换，不会打进应用。
