#!/usr/bin/env python3
"""将社区 RVC .pth（及可选 .index）转换为 FLOW Voice 原生安全的 .voicepack 目录。

输出结构（<output>/<pack_name>.voicepack/）：
- model.onnx     动态序列长度 ONNX 合成器（不含 pickle）
- index.f32bin   可选：从 FAISS .index 提取的紧凑 float32 向量库
- pack.json      架构、采样率、说话人数与哈希清单

用法：
  python3 convert_to_voicepack.py \
    --pth path/to/voice.pth \
    --index path/to/added.index \
    --name "MyVoice" \
    --output ./out
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import struct
import sys

import numpy as np
import onnxruntime as ort
import torch
import torch.nn as nn

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from rvc_models.models import (  # noqa: E402
    SynthesizerTrnMs256NSFsid,
    SynthesizerTrnMs256NSFsid_nono,
    SynthesizerTrnMs768NSFsid,
    SynthesizerTrnMs768NSFsid_nono,
)


class _SynthesizerONNXWrapperF0(nn.Module):
    """带 F0 的 RVC 合成器 ONNX 导出包装：显式接收 rnd，避免图内 RandomNormalLike。"""

    def __init__(self, net_g: nn.Module):
        super().__init__()
        self.net_g = net_g

    def forward(
        self,
        phone: torch.Tensor,
        phone_lengths: torch.Tensor,
        pitch: torch.Tensor,
        nsff0: torch.Tensor,
        sid: torch.Tensor,
        rnd: torch.Tensor,
    ) -> torch.Tensor:
        g = self.net_g.emb_g(sid).unsqueeze(-1)
        m_p, logs_p, x_mask = self.net_g.enc_p(phone, pitch, phone_lengths)
        z_p = (m_p + torch.exp(logs_p) * rnd * 0.66666) * x_mask
        z = self.net_g.flow(z_p, x_mask, g=g, reverse=True)
        o = self.net_g.dec(z * x_mask, nsff0, g=g)
        return o


class _SynthesizerONNXWrapperNoF0(nn.Module):
    """无 F0（nono）RVC 合成器 ONNX 导出包装。"""

    def __init__(self, net_g: nn.Module):
        super().__init__()
        self.net_g = net_g

    def forward(
        self,
        phone: torch.Tensor,
        phone_lengths: torch.Tensor,
        sid: torch.Tensor,
        rnd: torch.Tensor,
    ) -> torch.Tensor:
        g = self.net_g.emb_g(sid).unsqueeze(-1)
        m_p, logs_p, x_mask = self.net_g.enc_p(phone, None, phone_lengths)
        z_p = (m_p + torch.exp(logs_p) * rnd * 0.66666) * x_mask
        z = self.net_g.flow(z_p, x_mask, g=g, reverse=True)
        o = self.net_g.dec(z * x_mask, g=g)
        return o


def _bare_checkpoint_to_cpt(raw: dict, weight_path: pathlib.Path) -> dict:
    w = raw.get("model") or raw.get("weight") or raw
    emb_dim = int(w["enc_p.emb_phone.weight"].shape[1])
    version = "v2" if emb_dim == 768 else "v1"
    k0 = int(w["dec.ups.0.weight_v"].shape[2])
    if k0 == 16:
        sr, filt, up, kernels = 40000, 2048, [10, 10, 2, 2], [16, 16, 4, 4]
        seg = 12800
    elif k0 == 24:
        sr, filt, up, kernels = 48000, 2048, [12, 10, 2, 2], [24, 20, 4, 4]
        seg = 17280
    else:
        sr, filt, up, kernels = 32000, 1024, [10, 8, 2, 2], [20, 16, 4, 4]
        seg = 12800
    spec_channels = filt // 2 + 1
    config = [
        spec_channels, seg, 192, 192, 768, 2, 6, 3, 0.0, "1",
        [3, 7, 11], [[1, 3, 5], [1, 3, 5], [1, 3, 5]],
        up, 512, kernels, int(w["emb_g.weight"].shape[0]), 256, sr,
    ]
    stem = weight_path.name.lower()
    if_f0 = 0 if ("nof0" in stem or "nono" in stem or "enc_p.emb_pitch.weight" not in w) else 1
    return {"config": config, "weight": w, "f0": if_f0, "version": version}


def _export_index_f32bin(index_path: pathlib.Path, out_path: pathlib.Path) -> tuple[int, int]:
    import faiss

    idx = faiss.read_index(str(index_path))
    ntotal = int(idx.ntotal)
    dim = int(idx.d)
    if ntotal <= 0 or dim <= 0:
        raise ValueError(f"无效的 FAISS 索引 ({ntotal}x{dim}): {index_path}")
    vectors = np.ascontiguousarray(idx.reconstruct_n(0, ntotal), dtype="<f4")
    # 16 字节定长头：magic("F32I") + version(uint32=1) + rows(uint32) + cols(uint32)
    header = struct.pack("<4sIII", b"F32I", 1, ntotal, dim)
    with out_path.open("wb") as f:
        f.write(header)
        f.write(vectors.tobytes())
    return ntotal, dim


def _sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def convert_pth_to_voicepack(
    pth_path: pathlib.Path,
    output_dir: pathlib.Path,
    name: str | None = None,
    index_path: pathlib.Path | None = None,
    verify: bool = True,
) -> pathlib.Path:
    cpt = torch.load(pth_path, map_location="cpu", weights_only=False)
    if "config" not in cpt:
        cpt = _bare_checkpoint_to_cpt(cpt, pth_path)
    if "weight" not in cpt and "model" in cpt:
        cpt["weight"] = cpt["model"]

    config = list(cpt["config"])
    tgt_sr = int(config[-1])
    if isinstance(tgt_sr, str):
        tgt_sr = {"32k": 32000, "40k": 40000, "48k": 48000}.get(tgt_sr, 40000)
        config[-1] = tgt_sr
    n_spk = int(cpt["weight"]["emb_g.weight"].shape[0])
    config[-3] = n_spk
    inter_channels = int(config[2]) if len(config) > 2 else 192
    has_f0 = bool(int(cpt.get("f0", 1)) == 1)
    version = str(cpt.get("version", "v2"))
    emb_dim = 768 if version == "v2" else 256

    synth_cls = {
        ("v1", True): SynthesizerTrnMs256NSFsid,
        ("v1", False): SynthesizerTrnMs256NSFsid_nono,
        ("v2", True): SynthesizerTrnMs768NSFsid,
        ("v2", False): SynthesizerTrnMs768NSFsid_nono,
    }.get((version, has_f0), SynthesizerTrnMs768NSFsid)

    net_g = synth_cls(*config, is_half=False)
    if hasattr(net_g, "enc_q"):
        del net_g.enc_q
    # RVC checkpoints often store weight tensors in fp16; cast to fp32 cleanly before ONNX export.
    fp32_weights = {k: (v.float() if torch.is_floating_point(v) else v) for k, v in cpt["weight"].items()}
    net_g.load_state_dict(fp32_weights, strict=False)
    net_g.eval().float()

    pack_title = (name or pth_path.stem).strip() or pth_path.stem
    safe_dir_name = "".join(c if c.isalnum() or c in "-_ " else "_" for c in pack_title).strip() or "voice"
    pack_dir = output_dir / f"{safe_dir_name}.voicepack"
    pack_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = pack_dir / "model.onnx"

    t_dummy = 50
    phone = torch.randn(1, t_dummy, emb_dim, dtype=torch.float32)
    phone_lengths = torch.tensor([t_dummy], dtype=torch.int64)
    sid = torch.tensor([0], dtype=torch.int64)
    rnd = torch.randn(1, inter_channels, t_dummy, dtype=torch.float32)

    if has_f0:
        wrapper = _SynthesizerONNXWrapperF0(net_g).eval()
        pitch = torch.full((1, t_dummy), 120, dtype=torch.int64)
        nsff0 = torch.full((1, t_dummy), 220.0, dtype=torch.float32)
        inputs = (phone, phone_lengths, pitch, nsff0, sid, rnd)
        input_names = ["phone", "phone_lengths", "pitch", "nsff0", "sid", "rnd"]
        dynamic_axes = {
            "phone": {1: "n_frames"},
            "pitch": {1: "n_frames"},
            "nsff0": {1: "n_frames"},
            "rnd": {2: "n_frames"},
            "audio": {2: "n_samples"},
        }
    else:
        wrapper = _SynthesizerONNXWrapperNoF0(net_g).eval()
        inputs = (phone, phone_lengths, sid, rnd)
        input_names = ["phone", "phone_lengths", "sid", "rnd"]
        dynamic_axes = {
            "phone": {1: "n_frames"},
            "rnd": {2: "n_frames"},
            "audio": {2: "n_samples"},
        }

    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            inputs,
            str(onnx_path),
            export_params=True,
            opset_version=17,
            do_constant_folding=True,
            input_names=input_names,
            output_names=["audio"],
            dynamic_axes=dynamic_axes,
            dynamo=False,
        )

    if verify:
        sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        hop_samples = tgt_sr // 100  # 40k->400, 48k->480, 32k->320
        for test_t in (10, 37, 135):
            p_np = np.random.randn(1, test_t, emb_dim).astype(np.float32)
            l_np = np.array([test_t], dtype=np.int64)
            s_np = np.array([0], dtype=np.int64)
            r_np = np.random.randn(1, inter_channels, test_t).astype(np.float32)
            feed = {"phone": p_np, "phone_lengths": l_np, "sid": s_np, "rnd": r_np}
            if has_f0:
                feed["pitch"] = np.full((1, test_t), 120, dtype=np.int64)
                feed["nsff0"] = np.full((1, test_t), 220.0, dtype=np.float32)
            out = sess.run(["audio"], feed)[0]
            expected_samples = test_t * hop_samples
            assert out.shape == (1, 1, expected_samples), (
                f"动态长度 T={test_t} 期望 (1,1,{expected_samples})，实际 {out.shape}"
            )
            print(f"[verify T={test_t}] out.shape={out.shape} max={np.abs(out).max():.4f}")

    index_file: str | None = None
    index_rows = 0
    index_dim = 0
    if index_path is not None:
        idx_out = pack_dir / "index.f32bin"
        index_rows, index_dim = _export_index_f32bin(index_path, idx_out)
        if index_dim != emb_dim:
            raise ValueError(
                f"索引向量维度 ({index_dim}) 与模型版本 ({version}: {emb_dim}) 不匹配"
            )
        index_file = "index.f32bin"

    manifest = {
        "format": "flow-voicepack-v1",
        "name": pack_title,
        "engine": "rvc",
        "architecture": version,
        "hasF0": has_f0,
        "sampleRate": tgt_sr,
        "embeddingDim": emb_dim,
        "interChannels": inter_channels,
        "speakerCount": n_spk,
        "modelFile": "model.onnx",
        "indexFile": index_file,
        "indexRows": index_rows,
        "indexDim": index_dim,
        "f0UpKeyDefault": 0,
        "onnxSha256": _sha256_file(onnx_path),
    }
    (pack_dir / "pack.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"已生成 VoicePack: {pack_dir}")
    return pack_dir


def main() -> int:
    p = argparse.ArgumentParser(description="将 RVC .pth + .index 转换为原生 .voicepack")
    p.add_argument("--pth", required=True, type=pathlib.Path, help="源 .pth 权重路径")
    p.add_argument("--index", type=pathlib.Path, default=None, help="可选 FAISS .index 路径")
    p.add_argument("--name", type=str, default=None, help="音色名称（默认取 .pth 文件名）")
    p.add_argument("--output", type=pathlib.Path, default=pathlib.Path("./voicepacks"), help="输出目录")
    p.add_argument("--verify", action="store_true", default=True, help="使用 ONNX Runtime 校验动态维度")
    p.add_argument("--no-verify", action="store_false", dest="verify")
    args = p.parse_args()

    convert_pth_to_voicepack(
        pth_path=args.pth,
        output_dir=args.output,
        name=args.name,
        index_path=args.index,
        verify=args.verify,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
