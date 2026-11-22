# 第三方代码声明（rvc_models）

本目录的 Python 代码来自开源项目，仅供离线转换工具 `convert_to_voicepack.py` / `export_base_models.py` 使用，**不会打进 FLOW 应用**。
为了能导出 ONNX，部分文件做过修改（见各条说明）。

## Retrieval-based-Voice-Conversion-WebUI（RVC）

来源：https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI（`20240604` 分支 `infer/lib/infer_pack/*`、`infer/lib/rmvpe.py`）

- `commons.py`、`modules.py`：仅改了 import 路径
- `attentions.py`、`models.py`：为 ONNX 导出做了修改
- `transforms.py`：原样（其上游为 nsf，见下）

```
MIT License

Copyright (c) 2023 liujing04
Copyright (c) 2023 源文雨
Copyright (c) 2023 Ftps

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## VITS

`attentions.py`、`commons.py`、`modules.py`、`models.py` 的结构源自 VITS：https://github.com/jaywalnut310/vits

```
MIT License

Copyright (c) 2021 Jaehyeon Kim

（许可条文与上方 MIT License 相同）
```

## Neural Spline Flows（nsf）

`transforms.py` 源自 https://github.com/bayesiains/nsf

```
MIT License

Copyright (c) 2019 Conor Durkan, Artur Bekasov, Iain Murray, George Papamakarios

（许可条文与上方 MIT License 相同）
```

## RMVPE

`rmvpe.py` 源自 RMVPE（Dream-High，https://github.com/Dream-High/RMVPE），经 RVC 项目整理；**本仓库为 ONNX 导出做了修改**。
按 Apache License 2.0 分发，全文见同目录 [`LICENSE-APACHE-2.0.txt`](LICENSE-APACHE-2.0.txt)。
