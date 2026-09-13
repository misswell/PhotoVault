#!/usr/bin/env python3
"""Find a quantization configuration that survives the quality gate.

Why this exists: the first W8 attempt (per-channel symmetric int8 on every
linear layer — the obvious, documented default) degraded the vision tower to
min cosine 0.93 on real photos and dropped image nDCG@20 from 0.9986 to 0.9185.
That is an 8% retrieval loss, far outside the spec's 1.5% budget. A 4x smaller
model that retrieves badly is not a smaller model, it is a broken one — so the
configuration is chosen by measurement, not by taking the default.

Each candidate is scored on the full parity fixture set (57 images, 50 zh/en
queries) against the FP32/F16 reference embeddings:

    size on disk, min cosine on real photos, min cosine on all fixtures,
    image nDCG@20, and nDCG@20 relative loss vs the reference.

Usage
-----
    python tune_quantization.py --encoder image \
        --model out/SigLIP2ImageEncoder.mlpackage
    python tune_quantization.py --encoder text \
        --model out/SigLIP2TextEncoder.mlpackage
    # then apply the winner:
    python convert_siglip2.py --quantize w8 --suffix=-w8
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from verify_siglip2 import cosine_rows, ndcg_at_k  # noqa: E402


# --------------------------------------------------------------------------
def dir_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def load_fixtures(fixtures: Path) -> dict:
    m = json.loads((fixtures / "manifest.json").read_text(encoding="utf-8"))
    return {
        "image_input": np.fromfile(fixtures / "image_input.bin", dtype="<f4").reshape(m["image_input_shape"]),
        "text_input": np.fromfile(fixtures / "text_input.bin", dtype="<i4").reshape(m["text_input_shape"]),
        "image_embeddings": np.asarray(m["image_embeddings"], dtype=np.float32),
        "text_embeddings": np.asarray(m["text_embeddings"], dtype=np.float32),
        "image_kinds": m.get("image_kinds") or ["real"] * len(m["image_paths"]),
    }


def normalize(x: np.ndarray) -> np.ndarray:
    return x / np.maximum(np.linalg.norm(x, axis=1, keepdims=True), 1e-12)


def evaluate(model, encoder: str, fx: dict) -> dict:
    """Score one loaded MLModel on the fixtures."""
    if encoder == "image":
        x = fx["image_input"]
        ref = normalize(fx["image_embeddings"])
        got = np.vstack([
            np.asarray(model.predict({"image": x[i : i + 1]})["embedding"], dtype=np.float32).reshape(-1)
            for i in range(x.shape[0])
        ])
    else:
        x = fx["text_input"]
        ref = normalize(fx["text_embeddings"])
        got = np.vstack([
            np.asarray(model.predict({"input_ids": x[i : i + 1]})["embedding"], dtype=np.float32).reshape(-1)
            for i in range(x.shape[0])
        ])
    got = normalize(got)
    cos = cosine_rows(ref, got)

    # Retrieval quality: score every image against every query.
    img = normalize(fx["image_embeddings"])
    txt = normalize(fx["text_embeddings"])
    if encoder == "image":
        base_scores, cand_scores = img @ txt.T, got @ txt.T
    else:
        base_scores, cand_scores = img @ txt.T, img @ got.T

    n_img, n_txt = base_scores.shape
    ndcgs, top1 = [], 0
    for j in range(n_txt):
        ref_rank = list(np.argsort(-base_scores[:, j]))
        got_rank = list(np.argsort(-cand_scores[:, j]))
        relevant = set(ref_rank[: max(1, n_img // 4)])
        ndcgs.append(ndcg_at_k(got_rank, relevant, 20))
        if got_rank[0] in relevant:
            top1 += 1

    kinds = np.asarray([k == "real" for k in fx["image_kinds"]], dtype=bool)
    return {
        "min_cos_real": float(cos[kinds].min()) if kinds.any() else float("nan"),
        "min_cos_all": float(cos.min()),
        "mean_cos": float(cos.mean()),
        "ndcg20": float(np.mean(ndcgs)),
        "top1": f"{top1}/{n_txt}",
    }


# --------------------------------------------------------------------------
# Each candidate is (name, linear_config | None, palette_config | None,
#                     palette_op_types | None).
# `None` for a stage means "leave those weights at FP16".
# --------------------------------------------------------------------------
def image_configs():
    from coremltools.optimize.coreml import OpLinearQuantizerConfig as Lin, OpPalettizerConfig as Pal

    return [
        ("linear_sym_per_channel (ct default)", 
         Lin(mode="linear_symmetric", dtype=np.int8, granularity="per_channel"), None, None),
        ("linear_sym_per_block_32",
         Lin(mode="linear_symmetric", dtype=np.int8, granularity="per_block", block_size=32), None, None),
        ("linear_sym_per_block_16",
         Lin(mode="linear_symmetric", dtype=np.int8, granularity="per_block", block_size=16), None, None),
        ("palette_kmeans_8_grouped_32",
         None, Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32), None),
        ("palette_kmeans_8_grouped_16",
         None, Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=16), None),
        ("palette_kmeans_8_per_tensor",
         None, Pal(mode="kmeans", nbits=8, granularity="per_tensor"), None),
        ("palette_kmeans_6_grouped_32",
         None, Pal(mode="kmeans", nbits=6, granularity="per_grouped_channel", group_size=32), None),
        ("linear_sym_block_32 + palette_conv_8_grouped_32",
         Lin(mode="linear_symmetric", dtype=np.int8, granularity="per_block", block_size=32),
         Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32),
         {"conv": Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32)}),
    ]


def text_configs():
    """The text tower is 564.8 MB FP16, of which 393 MB is the 256000x768 token
    embedding table. So the embedding treatment decides the size result, and
    the linear layers can be left alone if that is what quality requires."""
    from coremltools.optimize.coreml import OpLinearQuantizerConfig as Lin, OpPalettizerConfig as Pal

    return [
        # Embedding-only: the zero-risk baseline for the size problem.
        ("embed_only_palette_8_grouped_32",
         None, Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32), None),
        ("embed_only_palette_8_grouped_16",
         None, Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=16), None),
        ("embed_only_palette_8_per_tensor",
         None, Pal(mode="kmeans", nbits=8, granularity="per_tensor"), None),
        # Embedding + linear.
        ("embed_palette_8_g32 + linear_sym_block_32",
         Lin(mode="linear_symmetric", dtype=np.int8, granularity="per_block", block_size=32),
         Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32), None),
        ("embed_palette_8_g32 + linear_palette_8_g32",
         None, Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32),
         {"linear": Pal(mode="kmeans", nbits=8, granularity="per_grouped_channel", group_size=32)}),
    ]


def apply_quantization(base_model, linear_cfg, palette_cfg, palette_op_types):
    """Apply the linear then the palettization stage. Returns a new MLModel."""
    from coremltools.optimize.coreml import (
        OptimizationConfig,
        linear_quantize_weights,
        palettize_weights,
    )

    model = base_model
    if linear_cfg is not None:
        model = linear_quantize_weights(model, config=OptimizationConfig(global_config=linear_cfg))
    if palette_cfg is not None:
        if palette_op_types is None:
            pconfig = OptimizationConfig(global_config=palette_cfg)
        else:
            pconfig = OptimizationConfig(global_config=None, op_type_configs=palette_op_types)
        model = palettize_weights(model, config=pconfig)
    return model


def run(args) -> int:
    import coremltools as ct

    fixtures = Path(args.fixtures)
    fx = load_fixtures(fixtures)
    src = Path(args.model)

    print(f"=== baseline (unquantized) {src}")
    base_model = ct.models.MLModel(str(src), compute_units=ct.ComputeUnit.ALL)
    base = evaluate(base_model, args.encoder, fx)
    base["mb"] = dir_size(src) / 1e6
    print(f"  {base['mb']:8.1f} MB  min_cos_real {base['min_cos_real']:.6f}  "
          f"min_cos_all {base['min_cos_all']:.6f}  nDCG@20 {base['ndcg20']:.4f}  top1 {base['top1']}")

    configs = image_configs() if args.encoder == "image" else text_configs()
    rows = []
    tmp = Path(tempfile.mkdtemp(prefix="tune-"))
    try:
        for name, lin, pal, pal_ops in configs:
            print(f"\n=== {name}", flush=True)
            t0 = time.time()
            try:
                out = apply_quantization(base_model, lin, pal, pal_ops)
                path = tmp / f"{args.encoder}-{abs(hash(name))}.mlpackage"
                out.save(str(path))
            except Exception as exc:  # noqa: BLE001
                print(f"  [SKIP] {type(exc).__name__}: {exc}")
                rows.append({"config": name, "error": f"{type(exc).__name__}: {exc}"})
                continue

            model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
            r = evaluate(model, args.encoder, fx)
            r["config"] = name
            r["mb"] = dir_size(path) / 1e6
            r["ndcg_loss_pct"] = (base["ndcg20"] - r["ndcg20"]) / base["ndcg20"] * 100
            r["seconds"] = time.time() - t0
            rows.append(r)
            print(f"  {r['mb']:8.1f} MB  min_cos_real {r['min_cos_real']:.6f}  "
                  f"min_cos_all {r['min_cos_all']:.6f}  nDCG@20 {r['ndcg20']:.4f}  "
                  f"loss {r['ndcg_loss_pct']:+.2f}%  ({r['seconds']:.0f}s)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n=== summary (gate: nDCG@20 loss <= 1.5% AND min cosine on real photos >= 0.99)")
    print(f"{'config':52s} {'MB':>7s} {'min_real':>9s} {'min_all':>9s} {'nDCG20':>8s} {'loss%':>7s}  verdict")
    for r in rows:
        if "error" in r:
            print(f"{r['config'][:52]:52s} {'—':>7s} {'—':>9s} {'—':>9s} {'—':>8s} {'—':>7s}  skipped")
            continue
        ok = r["ndcg_loss_pct"] <= 1.5 and r["min_cos_real"] >= 0.99
        print(f"{r['config'][:52]:52s} {r['mb']:7.1f} {r['min_cos_real']:9.6f} {r['min_cos_all']:9.6f} "
              f"{r['ndcg20']:8.4f} {r['ndcg_loss_pct']:+7.2f}  {'PASS' if ok else 'REJECT'}")

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps({"baseline": base, "results": rows}, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        print(f"\nwrote {args.json_out}")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--encoder", required=True, choices=["image", "text"])
    p.add_argument("--model", required=True, help="unquantized (FP16) mlpackage to quantize")
    p.add_argument("--fixtures", default=str(HERE / "build" / "parity"))
    p.add_argument("--json-out")
    return run(p.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
