#!/usr/bin/env python3
"""导出 FLOW Voice 所需的纯原生 ONNX 基础模型：
1. rmvpe.onnx         — 16kHz log-mel -> [1, n_frames, 360] F0 显著性图
2. hubert_base.onnx   — 16kHz 音频 -> (feat_v2 [1, F, 768], feat_v1 [1, F, 256])

用法：
  python3 export_base_models.py \
    --rmvpe-pt path/to/rmvpe.pt \
    --hubert-pt path/to/hubert_base.pt \
    --output-dir "$HOME/Library/Application Support/FLOW/Voice/Models"
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import sys
import types

import numpy as np
import onnxruntime as ort
import torch
import torch.nn as nn

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from rvc_models.rmvpe import E2E  # noqa: E402


class _FairseqDummy:
    def __init__(self, *args, **kwargs):
        pass

    def __setstate__(self, state):
        if isinstance(state, dict):
            self.__dict__.update(state)


def _load_hubert_final_proj(hubert_pt: pathlib.Path) -> nn.Linear:
    """从 fairseq 版 hubert_base.pt 提取 final_proj (768 -> 256) 线性层，用于 RVC v1。"""
    for mod in ("fairseq", "fairseq.data", "fairseq.data.dictionary"):
        if mod not in sys.modules:
            m = types.ModuleType(mod)
            m.Dictionary = _FairseqDummy
            sys.modules[mod] = m

    ckpt = torch.load(hubert_pt, map_location="cpu", weights_only=False)
    sd = ckpt["model"] if isinstance(ckpt, dict) and "model" in ckpt else ckpt
    proj_w = sd.get("final_proj.weight")
    proj_b = sd.get("final_proj.bias")
    if proj_w is None or proj_b is None:
        raise RuntimeError(f"{hubert_pt} 中未找到 final_proj 权重")
    linear = nn.Linear(768, 256)
    with torch.no_grad():
        linear.weight.copy_(proj_w.float())
        linear.bias.copy_(proj_b.float())
    return linear.eval()


class HubertDualWrapper(nn.Module):
    """包装 HuggingFace HubertModel，同时输出 v2(第12层 768维) 与 v1(第9层经 final_proj 256维)。"""

    def __init__(self, hf_model: nn.Module, final_proj: nn.Linear):
        super().__init__()
        self.hubert = hf_model
        self.final_proj = final_proj

    def forward(self, source: torch.Tensor):
        out = self.hubert(source, output_hidden_states=True)
        feat_v2 = out.last_hidden_state
        feat_v1_raw = out.hidden_states[9]
        feat_v1 = self.final_proj(feat_v1_raw)
        return feat_v2, feat_v1


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def export_rmvpe(rmvpe_pt: pathlib.Path, out_path: pathlib.Path, verify: bool) -> None:
    model = E2E(4, 1, (2, 2))
    state = torch.load(rmvpe_pt, map_location="cpu", weights_only=False)
    model.load_state_dict(state)
    model.eval().float()

    dummy_mel = torch.randn(1, 128, 128, dtype=torch.float32)
    with torch.no_grad():
        torch.onnx.export(
            model,
            (dummy_mel,),
            str(out_path),
            export_params=True,
            opset_version=17,
            do_constant_folding=True,
            input_names=["mel"],
            output_names=["salience"],
            dynamic_axes={
                "mel": {2: "n_frames"},
                "salience": {1: "n_frames"},
            },
            dynamo=False,
        )

    if verify:
        sess = ort.InferenceSession(str(out_path), providers=["CPUExecutionProvider"])
        for n_frames in (64, 160, 320):
            x = torch.randn(1, 128, n_frames, dtype=torch.float32)
            with torch.no_grad():
                ref = model(x).numpy()
            got = sess.run(["salience"], {"mel": x.numpy()})[0]
            diff = float(np.max(np.abs(ref - got)))
            print(f"[rmvpe.onnx] frames={n_frames} shape={got.shape} max_diff={diff:.2e}")
            assert diff < 1e-4, f"RMVPE ONNX 数值偏差过大: {diff}"


def export_hubert(
    hubert_pt: pathlib.Path,
    out_path: pathlib.Path,
    hf_cache_dir: pathlib.Path | None,
    hf_repo: str,
    verify: bool,
) -> None:
    from transformers import HubertModel

    kwargs = {}
    if hf_cache_dir is not None:
        kwargs["cache_dir"] = str(hf_cache_dir)
    hf_model = HubertModel.from_pretrained(hf_repo, **kwargs).float().eval()
    final_proj = _load_hubert_final_proj(hubert_pt)
    wrapper = HubertDualWrapper(hf_model, final_proj).eval()

    dummy_audio = torch.randn(1, 32000, dtype=torch.float32)
    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            (dummy_audio,),
            str(out_path),
            export_params=True,
            opset_version=17,
            do_constant_folding=True,
            input_names=["source"],
            output_names=["feat_v2", "feat_v1"],
            dynamic_axes={
                "source": {1: "n_samples"},
                "feat_v2": {1: "n_frames"},
                "feat_v1": {1: "n_frames"},
            },
            dynamo=False,
        )

    if verify:
        sess = ort.InferenceSession(str(out_path), providers=["CPUExecutionProvider"])
        for n_samples in (16000, 32000, 51200):
            x = torch.randn(1, n_samples, dtype=torch.float32)
            with torch.no_grad():
                ref_v2, ref_v1 = wrapper(x)
            got_v2, got_v1 = sess.run(["feat_v2", "feat_v1"], {"source": x.numpy()})
            d2 = float(np.max(np.abs(ref_v2.numpy() - got_v2)))
            d1 = float(np.max(np.abs(ref_v1.numpy() - got_v1)))
            print(f"[hubert_base.onnx] samples={n_samples} v2={got_v2.shape}({d2:.2e}) v1={got_v1.shape}({d1:.2e})")
            assert d2 < 1e-3 and d1 < 1e-3, f"HuBERT ONNX 数值偏差过大: d2={d2}, d1={d1}"

        # ContentVec 语义签名检验：禁止把原版 facebook/hubert-base-ls960 错导出为 RVC 编码器
        t = np.arange(8000, dtype=np.float32) / 16000.0
        probe = (0.3 * np.sin(2 * np.pi * 220 * t) + 0.15 * np.sin(2 * np.pi * 440 * t) + 0.1 * np.sin(2 * np.pi * 880 * t))[None, :]
        probe_v2 = sess.run(["feat_v2"], {"source": probe})[0][0]
        sig_score = float(probe_v2[:, [412, 663, 405, 666]].mean(axis=0).sum() - probe_v2[:, [558, 550, 79]].mean(axis=0).sum())
        print(f"[hubert_base.onnx] ContentVec 通道签名得分={sig_score:.3f} (阈值 > 1.2)")
        if sig_score <= 1.2:
            out_path.unlink(missing_ok=True)
            raise RuntimeError(
                f"导出的编码器未通过 ContentVec 特征签名检验 (score={sig_score:.3f})；请勿使用原版 facebook/hubert-base-ls960，应使用 lengyue233/content-vec-best"
            )


def main() -> int:
    default_models = pathlib.Path.home() / "Library/Application Support/FLOW/Voice/Models"
    p = argparse.ArgumentParser(description="导出 RMVPE 与 HuBERT/ContentVec 基础 ONNX 模型")
    p.add_argument("--rmvpe-pt", type=pathlib.Path, default=default_models / "rmvpe.pt")
    p.add_argument("--hubert-pt", type=pathlib.Path, default=default_models / "hubert_base.pt")
    p.add_argument("--hf-cache-dir", type=pathlib.Path, default=default_models / "hf")
    p.add_argument("--hf-repo", type=str, default="lengyue233/content-vec-best")
    p.add_argument("--output-dir", type=pathlib.Path, default=default_models)
    p.add_argument("--verify", action="store_true", default=True)
    p.add_argument("--no-verify", action="store_false", dest="verify")
    args = p.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    rmvpe_onnx = args.output_dir / "rmvpe.onnx"
    hubert_onnx = args.output_dir / "hubert_base.onnx"

    if args.rmvpe_pt.exists():
        print(f"正在导出 {rmvpe_onnx} ...")
        export_rmvpe(args.rmvpe_pt, rmvpe_onnx, verify=args.verify)
        print(f"完成 rmvpe.onnx (sha256={sha256_file(rmvpe_onnx)})")
    else:
        print(f"跳过 rmvpe（文件不存在: {args.rmvpe_pt}）", file=sys.stderr)

    if args.hubert_pt.exists():
        print(f"正在导出 {hubert_onnx} ...")
        hf_cache = args.hf_cache_dir if args.hf_cache_dir.exists() else None
        export_hubert(args.hubert_pt, hubert_onnx, hf_cache, args.hf_repo, verify=args.verify)
        print(f"完成 hubert_base.onnx (sha256={sha256_file(hubert_onnx)})")
    else:
        print(f"跳过 hubert（文件不存在: {args.hubert_pt}）", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
