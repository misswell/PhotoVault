#!/usr/bin/env python3
"""Simulate weight quantization in PyTorch before paying for Core ML conversion.

Core ML conversion of this model takes minutes per configuration, and
palettization with per-grouped-channel granularity takes ~15 minutes per sweep
point because k-means runs per group on CPU. Weight-only quantization is a pure
function of the weights, so the *quality* question — how far do the embeddings
move, and does retrieval ranking survive — can be answered in seconds in
PyTorch. Only the winning configurations are worth converting for real.

This ranks candidates. It does not replace verify_siglip2.py, which remains the
authority on the converted artifact.

Usage
-----
    python simulate_quantization.py --scope text
    python simulate_quantization.py --scope all --bits 8 --schemes per_channel per_block64
    python simulate_quantization.py --scope vision --embed-scheme keep
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from siglip2_reference import DEFAULT_CHECKPOINT_DIR, SigLIP2Reference  # noqa: E402
from verify_siglip2 import ndcg_at_k  # noqa: E402


# --------------------------------------------------------------------------
def quantize_weight(w: torch.Tensor, bits: int, scheme: str, symmetric: bool = True) -> torch.Tensor:
    """Uniform quantization of an [out, in] weight, mirroring coremltools.

      per_channel   -> one scale per output channel (coremltools default)
      per_blockN    -> one scale per N input elements within a row
                       (coremltools granularity="per_block", block_size=N)
      per_tensor    -> one scale for the whole tensor
    """
    qmax = 2 ** (bits - 1) - 1
    out_features = w.shape[0]
    x = w.detach().float().reshape(out_features, -1)

    if scheme == "per_tensor":
        groups = x.reshape(1, -1)
    elif scheme == "per_channel":
        groups = x
    elif scheme == "per_input_channel":
        # One scale per *input* dimension (block [C_out, 1] in coremltools'
        # table). Worth distinguishing: for ViT weights this is markedly worse
        # than per-output-channel, and if coremltools' `per_channel` means this,
        # the simulation explains the converted model's behaviour.
        groups = x.t().reshape(x.shape[1], -1)
        out_features = x.shape[1]
    elif scheme.startswith("per_block"):
        block = int(scheme.removeprefix("per_block"))
        pad = (-x.shape[1]) % block
        if pad:
            x = torch.nn.functional.pad(x, (0, pad))
        groups = x.reshape(x.shape[0], -1, block)
    else:
        raise ValueError(f"unknown scheme {scheme!r}")

    lo = groups.amin(dim=-1, keepdim=True)
    hi = groups.amax(dim=-1, keepdim=True)
    if symmetric:
        scale = torch.maximum(lo.abs(), hi.abs()).clamp_min(1e-12) / qmax
        zero = torch.zeros_like(scale)
    else:
        scale = ((hi - lo) / (2 * qmax)).clamp_min(1e-12)
        zero = torch.round(-lo / scale)

    deq = (torch.round(groups / scale + zero).clamp(-qmax - 1, qmax) - zero) * scale
    deq = deq.reshape(out_features, -1)
    if scheme == "per_input_channel":
        deq = deq.t()
    return deq[:, : w.reshape(w.shape[0], -1).shape[1]].reshape(w.shape).to(w.dtype)


def quantize_embeddings(table: torch.Tensor, bits: int, group: int | None) -> torch.Tensor:
    """Symmetric quantization of a [vocab, dim] table, per-row or per-group."""
    qmax = 2 ** (bits - 1) - 1
    W = table.detach().float()
    if group is None:
        scale = W.abs().amax(dim=1, keepdim=True).clamp_min(1e-12) / qmax
        return ((W / scale).round().clamp(-qmax - 1, qmax) * scale).to(table.dtype)
    rows, dim = W.shape
    if dim % group:
        raise ValueError(f"dim {dim} not divisible by group {group}")
    Wg = W.view(rows, dim // group, group)
    scale = Wg.abs().amax(dim=2, keepdim=True).clamp_min(1e-12) / qmax
    return ((Wg / scale).round().clamp(-qmax - 1, qmax) * scale).view(rows, dim).to(table.dtype)


def norm(x: np.ndarray) -> np.ndarray:
    return x / np.maximum(np.linalg.norm(x, axis=1, keepdims=True), 1e-12)


def ranked_ndcg(base_scores: np.ndarray, cand_scores: np.ndarray) -> float:
    n = base_scores.shape[0]
    out = []
    for j in range(base_scores.shape[1]):
        ref_rank = list(np.argsort(-base_scores[:, j]))
        got_rank = list(np.argsort(-cand_scores[:, j]))
        out.append(ndcg_at_k(got_rank, set(ref_rank[: max(1, n // 4)]), 20))
    return float(np.mean(out))


# --------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT_DIR))
    p.add_argument("--scope", default="text", choices=["all", "text", "vision"],
                   help="which tower's linear layers to quantize")
    p.add_argument("--bits", type=int, nargs="*", default=[8])
    p.add_argument("--schemes", nargs="*", default=["per_channel", "per_block64", "per_block128", "per_tensor"])
    p.add_argument("--asymmetric", action="store_true", help="use min/max range instead of symmetric")
    p.add_argument("--embed-scheme", default="per_group64",
                   help="token embedding: keep | per_tensor | per_row | per_groupN")
    p.add_argument("--fixtures", default=str(HERE / "build" / "parity"))
    p.add_argument("--json-out")
    args = p.parse_args()

    fx = Path(args.fixtures)
    m = json.loads((fx / "manifest.json").read_text(encoding="utf-8"))
    ids = torch.from_numpy(np.fromfile(fx / "text_input.bin", dtype="<i4").reshape(m["text_input_shape"]))
    pixel = torch.from_numpy(np.fromfile(fx / "image_input.bin", dtype="<f4").reshape(m["image_input_shape"]))
    ref_txt_n = norm(np.asarray(m["text_embeddings"], dtype=np.float32))
    ref_img_n = norm(np.asarray(m["image_embeddings"], dtype=np.float32))
    kinds = np.asarray([k == "real" for k in (m.get("image_kinds") or ["real"] * len(ref_img_n))], dtype=bool)
    base_scores = ref_img_n @ ref_txt_n.T

    print("loading reference ...", flush=True)
    ref = SigLIP2Reference.load(args.checkpoint, device="cpu")
    text_model, vision_model = ref.model.text_model, ref.model.vision_model
    pristine = {n: p.detach().clone() for n, p in ref.model.named_parameters()}
    total_params = sum(p.numel() for p in ref.model.parameters())

    embed_group = {"keep": -1, "per_tensor": None, "per_row": 0}.get(args.embed_scheme)
    if embed_group is None and args.embed_scheme not in ("per_tensor", "keep"):
        embed_group = int(args.embed_scheme.removeprefix("per_group"))

    def restore():
        for n, p in ref.model.named_parameters():
            p.data.copy_(pristine[n])

    def size_mb(linear_bits: int, embed_bits: int, other_bits: int = 16) -> float:
        """Bytes implied by the quantization, counting each parameter once."""
        total = 0
        for name, p in ref.model.named_parameters():
            if "token_embedding" in name:
                total += p.numel() * embed_bits / 8
            elif name.endswith(".weight") and _is_linear_weight(name):
                total += p.numel() * linear_bits / 8
            elif "in_proj_weight" in name:
                total += p.numel() * other_bits / 8
            else:
                total += p.numel() * other_bits / 8
        return total / 1e6

    linear_weight_names = {
        n for n, _ in ref.model.named_parameters() if n.endswith(".weight")
    }

    def _is_linear_weight(name: str) -> bool:
        mod = ref.model
        for part in name.split(".")[:-1]:
            mod = getattr(mod, part, None)
            if mod is None:
                return False
        return isinstance(mod, torch.nn.Linear)

    linear_names = {n for n in linear_weight_names if _is_linear_weight(n)}

    def apply(scope: str, bits: int, scheme: str) -> int:
        """Quantize selected weight tensors; returns how many were touched.

        Covers nn.Linear weights *and* raw 2-D projection weights such as
        MultiheadAttention.in_proj_weight. The latter matters here: the
        converted Core ML graph comes from ManualMAPHead, which implements the
        attention projection as three separate `linear` ops, so Core ML
        quantizes weights that a naive nn.Linear-only sweep would miss.
        """
        targets = {"all": (text_model, vision_model), "text": (text_model,), "vision": (vision_model,)}[scope]
        touched = 0
        for module in targets:
            for name, sub in module.named_modules():
                if isinstance(sub, torch.nn.Linear):
                    sub.weight.data.copy_(quantize_weight(sub.weight.data, bits, scheme, not args.asymmetric))
                    touched += 1
                elif hasattr(sub, "in_proj_weight") and sub.in_proj_weight is not None:
                    w = sub.in_proj_weight
                    w.data.copy_(quantize_weight(w.data, bits, scheme, not args.asymmetric))
                    touched += 1
        return touched

    def measure(label: str, linear_bits: int, embed_bits: int, txt, img):
        tcos = (norm(txt) * ref_txt_n).sum(1)
        txt_scores = norm(txt)
        parts = [f"txt min {tcos.min():.6f} mean {tcos.mean():.6f}"]
        row = {
            "label": label,
            "text_min_cos": float(tcos.min()),
            "text_mean_cos": float(tcos.mean()),
            "size_mb": size_mb(linear_bits, embed_bits),
        }
        if img is not None:
            icos = (norm(img) * ref_img_n).sum(1)
            parts.insert(0, f"img real {icos[kinds].min():.6f} all {icos.min():.6f}")
            row["image_min_cos_real"] = float(icos[kinds].min())
            row["image_min_cos_all"] = float(icos.min())
            cand = norm(img) @ txt_scores.T
        else:
            cand = ref_img_n @ txt_scores.T
        row["ndcg20"] = ranked_ndcg(base_scores, cand)
        parts.append(f"nDCG@20 {row['ndcg20']:.4f}")
        print(f"  {label:46s} {row['size_mb']:7.1f} MB  " + "  ".join(parts), flush=True)
        return row

    print(f"\n=== control (fp32, {total_params/1e6:.1f}M params)")
    restore()
    with torch.no_grad():
        t0 = ref.text_embedding_from_ids(ids)
        i0 = ref.image_embedding_from_tensor(pixel) if args.scope in ("all", "vision") else None
    rows = [measure("fp32 control", 32, 32, t0, i0)]
    print(f"  {'(fp16 reference size)':46s} {size_mb(16, 16):7.1f} MB")

    for bits in args.bits:
        for scheme in args.schemes:
            label = f"{bits}-bit {scheme}{' asym' if args.asymmetric else ''}"
            print(f"\n=== {label}  scope={args.scope}  embed={args.embed_scheme}")
            restore()
            n_lin = apply(args.scope, bits, scheme)
            embed_bits = 16
            if args.scope in ("all", "text") and embed_group != -1:
                table = text_model.embeddings.token_embedding.weight
                table.data.copy_(quantize_embeddings(table.data, bits, embed_group))
                embed_bits = bits
            with torch.no_grad():
                t = ref.text_embedding_from_ids(ids)
                i = ref.image_embedding_from_tensor(pixel) if args.scope in ("all", "vision") else None
            row = measure(label, bits, embed_bits, t, i)
            row["linear_layers_quantized"] = n_lin
            row["bits"] = bits
            row["scheme"] = scheme
            rows.append(row)

    restore()
    print("\n=== gate: nDCG@20 loss <= 1.5% vs control")
    base = rows[0]
    for r in rows[1:]:
        loss = (base["ndcg20"] - r["ndcg20"]) / base["ndcg20"] * 100
        real = r.get("image_min_cos_real")
        ok = loss <= 1.5 and (real is None or real >= 0.99)
        print(f"  {r['label'][:46]:46s} loss {loss:+6.2f}%  "
              f"img_real {real if real is None else round(real, 6)}  {'PASS' if ok else 'REJECT'}")
        r["ndcg_loss_pct"] = loss

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(rows, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
