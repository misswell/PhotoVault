#!/usr/bin/env python3
"""Benchmark SigLIP2 (reference and/or converted Core ML) for PhotoVault.

Produces the numbers the spec asks for:

  * image encode throughput (images/sec) and text encode latency P50/P95
  * mlpackage size on disk
  * exact-retrieval latency over a synthetic N-photo embedding matrix
    (the spec's targets are P50 < 500 ms / P95 < 1000 ms at 100k on device)
  * retrieval quality: nDCG@20 / Recall@k / MRR for a candidate model against a
    baseline, which is the gate for accepting a quantization level
    (nDCG@20 must stay within 1.5% of FP16)

IMPORTANT: numbers measured on this Mac are a *floor and a sanity check*, not a
device claim. The spec forbids concluding device performance from a Mac, and
the retrieval stage in the app is a Metal kernel that this script does not
exercise. Use these to catch regressions and to compare quantization levels.

Usage
-----
    python benchmark_siglip2.py --mode reference
    python benchmark_siglip2.py --mode coreml \
        --image-model out/SigLIP2ImageEncoder.mlpackage \
        --text-model out/SigLIP2TextEncoder.mlpackage --label fp16
    python benchmark_siglip2.py --compare out/SigLIP2TextEncoder.mlpackage:fp16 \
        out/SigLIP2TextEncoder-w8.mlpackage:w8 --fixtures build/parity
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from siglip2_reference import DEFAULT_CHECKPOINT_DIR, SigLIP2Reference  # noqa: E402
from verify_siglip2 import PARITY_QUERIES, ndcg_at_k, real_images  # noqa: E402


def percentile(values: list[float], p: float) -> float:
    return float(np.percentile(np.asarray(values), p)) if values else float("nan")


def dir_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def synthetic_library(n: int, dim: int, seed: int = 1) -> np.ndarray:
    """Unit-norm FP16 embedding matrix, the way EmbeddingStore will hold it."""
    rng = np.random.default_rng(seed)
    m = rng.standard_normal((n, dim)).astype(np.float16)
    m /= np.maximum(np.linalg.norm(m.astype(np.float32), axis=1, keepdims=True), 1e-6)
    return m


def bench_retrieval(library: np.ndarray, queries: np.ndarray, repeats: int = 20) -> dict:
    """Exact dot-product search: the numerical floor the Metal kernel must beat."""
    lf = library.astype(np.float32)
    times = []
    for i in range(repeats):
        q = queries[i % queries.shape[0]]
        t0 = time.perf_counter()
        scores = lf @ q
        idx = np.argpartition(-scores, 1000)[:1000]
        _ = idx[np.argsort(-scores[idx])]
        times.append((time.perf_counter() - t0) * 1000.0)
    return {
        "photos": int(library.shape[0]),
        "dim": int(library.shape[1]),
        "p50_ms": percentile(times, 50),
        "p95_ms": percentile(times, 95),
        "matrix_mb": round(library.nbytes / 1e6, 1),
        "note": "numpy/BLAS on this Mac — a floor, not a device measurement",
    }


def bench_coreml(args) -> int:
    import coremltools as ct

    result = {"mode": "coreml", "label": args.label}
    facts = json.loads(Path(args.manifest).read_text(encoding="utf-8")) if args.manifest else None
    dim = facts["embeddingDimension"] if facts else 768
    image_size = facts["imageSize"] if facts else 256
    text_len = facts["textMaxLength"] if facts else 64

    if args.image_model:
        model = ct.models.MLModel(args.image_model, compute_units=ct.ComputeUnit.ALL)
        path = Path(args.image_model)
        result["image_encoder"] = {"path": str(path), "mb": round(dir_size(path) / 1e6, 1)}
        x = np.random.default_rng(0).standard_normal((1, 3, image_size, image_size)).astype(np.float32)
        for _ in range(args.warmup):
            model.predict({args.image_input_name: x})
        times = []
        for _ in range(args.image_runs):
            t0 = time.perf_counter()
            model.predict({args.image_input_name: x})
            times.append(time.perf_counter() - t0)
        result["image_encoder"].update({
            "runs": args.image_runs,
            "ms_p50": percentile(times, 50) * 1000,
            "ms_p95": percentile(times, 95) * 1000,
            "images_per_sec": 1.0 / float(np.mean(times)),
        })

    if args.text_model:
        model = ct.models.MLModel(args.text_model, compute_units=ct.ComputeUnit.ALL)
        path = Path(args.text_model)
        result["text_encoder"] = {"path": str(path), "mb": round(dir_size(path) / 1e6, 1)}
        ids = np.zeros((1, text_len), dtype=np.int32)
        ids[0, :6] = [235250, 2686, 576, 476, 4401, 1]
        for _ in range(args.warmup):
            model.predict({args.text_input_name: ids})
        times = []
        for _ in range(args.text_runs):
            t0 = time.perf_counter()
            model.predict({args.text_input_name: ids})
            times.append(time.perf_counter() - t0)
        result["text_encoder"].update({
            "runs": args.text_runs,
            "ms_p50": percentile(times, 50) * 1000,
            "ms_p95": percentile(times, 95) * 1000,
        })

    if args.library_size > 0:
        library = synthetic_library(args.library_size, dim)
        queries = synthetic_library(32, dim, seed=99)
        result["retrieval"] = bench_retrieval(library, queries)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0


def bench_reference(args) -> int:
    ref = SigLIP2Reference.load(args.checkpoint, device=args.device)
    f = ref.facts
    result = {"mode": "reference", "device": args.device, "facts": f.as_manifest()}

    imgs = real_images()[: max(1, min(8, len(real_images())))]
    if not imgs:
        print("no images available for the image benchmark; pass --images")
        return 1
    pixel = ref.image_tensor(imgs)
    x = pixel[0:1]

    import torch

    with torch.no_grad():
        for _ in range(args.warmup):
            ref.image_embedding_from_tensor(x)
        times = []
        for _ in range(args.image_runs):
            t0 = time.perf_counter()
            ref.image_embedding_from_tensor(x)
            times.append(time.perf_counter() - t0)
    result["image_encoder"] = {
        "device": args.device,
        "ms_p50": percentile(times, 50) * 1000,
        "ms_p95": percentile(times, 95) * 1000,
        "images_per_sec": 1.0 / float(np.mean(times)),
    }

    ids = ref.token_ids(["a photo of a cat"])
    with torch.no_grad():
        for _ in range(args.warmup):
            ref.text_embedding_from_ids(ids)
        times = []
        for _ in range(args.text_runs):
            t0 = time.perf_counter()
            ref.text_embedding_from_ids(ids)
            times.append(time.perf_counter() - t0)
    result["text_encoder"] = {
        "ms_p50": percentile(times, 50) * 1000,
        "ms_p95": percentile(times, 95) * 1000,
    }

    if args.library_size > 0:
        library = synthetic_library(args.library_size, f.embedding_dimension)
        queries = synthetic_library(32, f.embedding_dimension, seed=99)
        result["retrieval"] = bench_retrieval(library, queries)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(f"\nwrote {args.json_out}")
    return 0


def compare_quality(fixtures: Path, candidates: list[tuple[str, str]]) -> int:
    """Ranking-quality gate for a quantization level (spec section 6).

    Rather than only comparing vectors, this compares *retrieval ranking*: the
    spec's acceptance rule is that a quantized model must not lose more than
    1.5% nDCG@20 relative to FP16.
    """
    import coremltools as ct

    manifest = json.loads((fixtures / "manifest.json").read_text(encoding="utf-8"))
    ref_img = np.asarray(manifest["image_embeddings"], dtype=np.float32)
    ref_txt = np.asarray(manifest["text_embeddings"], dtype=np.float32)
    ids = np.fromfile(fixtures / "text_input.bin", dtype="<i4").reshape(manifest["text_input_shape"])
    baseline_scores = ref_img @ ref_txt.T

    def evaluate(path: str, label: str, baseline: np.ndarray | None):
        model = ct.models.MLModel(path, compute_units=ct.ComputeUnit.ALL)
        outputs = []
        for i in range(ids.shape[0]):
            pred = model.predict({"input_ids": ids[i : i + 1]})
            outputs.append(np.asarray(pred["embedding"], dtype=np.float32).reshape(-1))
        emb = np.vstack(outputs)
        emb /= np.maximum(np.linalg.norm(emb, axis=1, keepdims=True), 1e-12)
        scores = ref_img @ emb.T

        n_img, n_txt = baseline_scores.shape
        ndcgs, recalls, mrrs = [], [], []
        for j in range(n_txt):
            ref_rank = list(np.argsort(-baseline_scores[:, j]))
            got_rank = list(np.argsort(-scores[:, j]))
            relevant = set(ref_rank[: max(1, n_img // 4)])
            ndcgs.append(ndcg_at_k(got_rank, relevant, 20))
            recalls.append(len(set(got_rank[:20]) & relevant) / len(relevant))
            mrr = 0.0
            for rank, item in enumerate(got_rank, start=1):
                if item in relevant:
                    mrr = 1.0 / rank
                    break
            mrrs.append(mrr)
        return {
            "label": label,
            "path": path,
            "mb": round(dir_size(Path(path)) / 1e6, 1),
            "ndcg_at_20": float(np.mean(ndcgs)),
            "recall_at_20": float(np.mean(recalls)),
            "mrr": float(np.mean(mrrs)),
        }

    base = evaluate(candidates[0][0], candidates[0][1], None)
    rows = [base]
    for path, label in candidates[1:]:
        row = evaluate(path, label, baseline_scores)
        row["ndcg_relative_loss_pct"] = (base["ndcg_at_20"] - row["ndcg_at_20"]) / base["ndcg_at_20"] * 100
        rows.append(row)

    print(json.dumps({"baseline": base["label"], "results": rows}, indent=2, ensure_ascii=False))
    worst = max((r.get("ndcg_relative_loss_pct", 0.0) for r in rows), default=0.0)
    print(f"\nworst nDCG@20 relative loss: {worst:.2f}%  (gate: <= 1.5%)")
    return 0 if worst <= 1.5 else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", default="reference", choices=["reference", "coreml"])
    p.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT_DIR))
    p.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    p.add_argument("--image-model")
    p.add_argument("--text-model")
    p.add_argument("--manifest")
    p.add_argument("--label")
    p.add_argument("--image-input-name", default="image")
    p.add_argument("--text-input-name", default="input_ids")
    p.add_argument("--image-runs", type=int, default=20)
    p.add_argument("--text-runs", type=int, default=50)
    p.add_argument("--warmup", type=int, default=3)
    p.add_argument("--library-size", type=int, default=100_000)
    p.add_argument("--json-out")
    p.add_argument("--compare", nargs="*", default=[],
                   help="path:label pairs to compare ranking quality, first is the baseline")
    p.add_argument("--fixtures", default=str(HERE / "build" / "parity"))
    args = p.parse_args()

    if args.compare:
        pairs = []
        for item in args.compare:
            path, _, label = item.partition(":")
            pairs.append((path, label or Path(path).stem))
        return compare_quality(Path(args.fixtures), pairs)

    if args.mode == "coreml":
        return bench_coreml(args)
    return bench_reference(args)


if __name__ == "__main__":
    raise SystemExit(main())
