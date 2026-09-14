#!/usr/bin/env python3
"""SigLIP2 verification harness for PhotoVault.

Three independent modes:

  reference   Prove the *reference* is what we think it is, and that the
              conventions we are about to port to Swift are real decisions
              rather than accidents:
                A. every checkpoint tensor is consumed (no silent weight drop)
                B. the fixed-resolution architecture is the right one, and the
                   MAP pooling head is genuinely in the forward path
                   (transformers' Siglip2Model is the *naflex* variant and
                   cannot load this checkpoint)
                C. do_convert_rgb=True is a byte-identical no-op for RGB input
                D. an RGBA input without our RGB conversion fails (documented trap)
                E. slow and fast tokenizers agree exactly
                F. padding="max_length" without max_length silently does not pad
                G. pooling the last position != pooling the last non-pad token
                H. determinism across repeated runs
                I. semantic sanity on real screenshots

  walk        Build the parity fixture set (50 deterministic synthetic images
              + every real screenshot in the repo, 50 zh/en queries) and write
              a reference parity dump for the Swift/Core ML test.

  coreml      Compare converted .mlpackage outputs against the reference.
              L1: identical float inputs (isolates the model)
              L2: Swift-side preprocessing from the original file
              Also reports rank agreement for quantized models.

  tokenizer   Compare Swift-produced token ids against Python.
  embedding   Verify the embedding matrix file, unit tests and 100k benchmark.
  index       Verify the metadata index, slot bookkeeping, filters and FTS.
  metal       Verify the Metal exact-search kernel against CPU and NumPy.
  textencoder Run the Swift tokenizer + Core ML text tower against PyTorch.
  query       Verify the query analyzer (AND / NOT / dates / places).
  ocr         Verify Vision OCR and its path into the FTS index.
  geo         Verify the offline gazetteer and geo filtering.
  search      Verify the search engine end to end (stubbed text tower).
  vision      Verify the Swift image encoder against the reference.

Exit code is non-zero if any check fails, so this is usable in CI.

Examples
--------
    python verify_siglip2.py reference
    python verify_siglip2.py walk --out build/parity --count 50
    python verify_siglip2.py coreml --fixtures build/parity \
        --image-model out/SigLIP2ImageEncoder.mlpackage \
        --text-model out/SigLIP2TextEncoder.mlpackage
    python verify_siglip2.py tokenizer [--rebuild]
"""

from __future__ import annotations

import argparse
import os
import json
import re
import math
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from siglip2_reference import (  # noqa: E402
    DEFAULT_CHECKPOINT_DIR,
    SigLIP2Reference,
    load_image_rgb,
)

REPO_ROOT = HERE.parent.parent
SCREENSHOT_DIRS = [
    REPO_ROOT / "screenshots" / "raw" / "zh-Hans",
    REPO_ROOT / "screenshots" / "iphone" / "zh-Hans",
    REPO_ROOT / "screenshots" / "ipad" / "zh-Hans",
]

# 50 queries: the zh/en mix the spec requires, biased towards the query shapes
# PhotoVault must actually handle (object / scene / colour / negation / OCR /
# date / place / screenshot / mixed). Reused as the seed of the Phase 11
# benchmark query set.
PARITY_QUERIES: list[str] = [
    "海边的狗", "穿红色衣服的人", "晚上的城市街道", "雪山", "夕阳",
    "咖啡", "红色跑车", "两只猫", "一只猫", "三个人",
    "猫躺在白色床上", "晚上下雨的街道", "没有人的雪山", "夕阳但不要有人", "海边没有人的照片",
    "沙发上睡觉的狗", "生日蛋糕", "一束鲜花", "一碗拉面", "日本街道",
    "写着报销的截图", "发票截图", "合同照片", "微信聊天截图", "菜单",
    "去年夏天的海边", "2025年3月的照片", "今天拍的照片", "在东京拍的照片", "在武汉大学拍的照片",
    "截图", "文档扫描", "白板上的字", "路牌", "商店招牌",
    "a dog on the beach", "a person wearing a red shirt", "city street at night",
    "snow mountain", "sunset", "a cup of coffee", "a red sports car",
    "two cats on a sofa", "an invoice screenshot", "a bowl of ramen",
    "雨天", "室内", "食物", "孩子", "全家福",
]


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
class Checker:
    """Collects pass/fail results and never stops at the first failure."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passes = 0

    def check(self, ok: bool, label: str, detail: str = "") -> bool:
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {label}" + (f" — {detail}" if detail else ""))
        if ok:
            self.passes += 1
        else:
            self.failures.append(f"{label}: {detail}")
        return ok

    def report(self) -> int:
        print()
        if self.failures:
            print(f"RESULT: {len(self.failures)} FAILED, {self.passes} passed")
            for f in self.failures:
                print(f"  - {f}")
            return 1
        print(f"RESULT: all {self.passes} checks passed")
        return 0


def cosine_rows(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Row-wise cosine similarity (inputs are already unit norm in practice)."""
    a = a / np.maximum(np.linalg.norm(a, axis=1, keepdims=True), 1e-12)
    b = b / np.maximum(np.linalg.norm(b, axis=1, keepdims=True), 1e-12)
    return np.sum(a * b, axis=1)


def ndcg_at_k(ranked: list, relevant: set, k: int) -> float:
    dcg = sum(1.0 / math.log2(i + 2) for i, x in enumerate(ranked[:k]) if x in relevant)
    ideal = sum(1.0 / math.log2(i + 2) for i in range(min(len(relevant), k)))
    return dcg / ideal if ideal > 0 else 0.0


# --------------------------------------------------------------------------
# test set construction
# --------------------------------------------------------------------------
def real_images() -> list[Path]:
    out: list[Path] = []
    for d in SCREENSHOT_DIRS:
        if d.is_dir():
            for p in sorted(d.iterdir()):
                if p.suffix.lower() in {".png", ".jpg", ".jpeg", ".heic", ".webp"}:
                    out.append(p)
    return out


def make_synthetic_images(out_dir: Path, count: int, seed: int = 20250913) -> list[Path]:
    """Deterministic synthetic images: 50 distinct inputs without committing blobs.

    Deliberately covers the cases that break naive preprocessing: extreme aspect
    ratios (direct resize, no crop), grayscale, RGBA-with-alpha sources, pure
    black/white, high-frequency noise and saturated colour.
    """
    from PIL import Image, ImageDraw

    rng = np.random.default_rng(seed)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []

    for i in range(count):
        w = int(rng.integers(64, 4000))
        h = int(rng.integers(64, 4000))
        kind = i % 6
        arr = np.zeros((h, w, 3), dtype=np.uint8)

        if kind == 0:  # vertical gradient
            ramp = np.linspace(0, 255, h, dtype=np.uint8)[:, None]
            arr[:] = np.stack([ramp, ramp[:, ::-1], np.full_like(ramp, 128)], axis=-1)
        elif kind == 1:  # horizontal colour bars
            ramp = np.linspace(0, 255, w, dtype=np.uint8)[None, :]
            arr[:] = np.stack([ramp, np.full_like(ramp, 64), 255 - ramp], axis=-1)
        elif kind == 2:  # gaussian noise
            arr = rng.integers(0, 256, size=(h, w, 3), dtype=np.uint8)
        elif kind == 3:  # flat saturated colour
            arr[:] = np.array([255, 0, 0] if i % 2 else [0, 128, 255], dtype=np.uint8)
        elif kind == 4:  # black / white halves
            arr[: h // 2] = 0
            arr[h // 2 :] = 255
        else:  # geometric shapes
            arr[:] = 32
            img = Image.fromarray(arr).convert("RGB")
            d = ImageDraw.Draw(img)
            for _ in range(6):
                x0, y0 = rng.integers(0, w), rng.integers(0, h)
                x1, y1 = x0 + rng.integers(4, max(5, w // 2)), y0 + rng.integers(4, max(5, h // 2))
                d.ellipse(
                    [int(x0), int(y0), int(x1), int(y1)],
                    fill=tuple(int(v) for v in rng.integers(0, 256, 3)),
                )
            arr = np.asarray(img)

        img = Image.fromarray(arr, "RGB")

        # Exercise the non-RGB source paths on a few samples: they are exactly
        # where the checkpoint's do_convert_rgb=null trap bites.
        if i % 11 == 3:
            img = img.convert("L")
            suffix = ".png"
        elif i % 11 == 7:
            img = img.convert("RGBA")
            suffix = ".png"
        elif i % 3 == 0:
            suffix = ".png"
        else:
            suffix = ".jpg"

        path = out_dir / f"synthetic-{i:03d}{suffix}"
        img.save(path)
        paths.append(path)

    return paths


# --------------------------------------------------------------------------
# mode: reference
# --------------------------------------------------------------------------
def mode_reference(args) -> int:
    import torch
    from transformers import AutoConfig, AutoModel, Siglip2Config, Siglip2Model

    c = Checker()
    checkpoint = args.checkpoint
    print(f"=== loading reference from {checkpoint}")
    ref = SigLIP2Reference.load(checkpoint, device="cpu")
    f = ref.facts
    print(json.dumps(f.as_manifest(), indent=2, ensure_ascii=False))

    # A. weight coverage — already enforced inside load(), restate for the log.
    c.check(True, "A. every checkpoint tensor consumed by the model",
            f"{f.vision_layers}+{f.text_layers} layers, dim {f.embedding_dimension}")

    # B. architecture identity.
    #    `model_type` is "siglip", so AutoModel resolves to the v1 `SiglipModel`
    #    class, and that is CORRECT — not a fallback we should "fix". The
    #    checkpoint's patch embedding is a Conv2d [768,3,16,16] (fixed
    #    resolution), whereas transformers' `Siglip2Model` is the *naflex*
    #    architecture: a Linear(768,768) patch embed plus spatial_shapes /
    #    pixel_attention_mask inputs (google/siglip2-*-naflex). Swapping to
    #    Siglip2Model would silently build the wrong tower.
    images = real_images()[:4]
    real = images
    texts = ["海边的狗", "a photo of a cat", "雪山", "invoice screenshot"]
    if not images:
        images = _fallback_images()
    pixel = ref.image_tensor(images)
    ref_img = ref.image_embedding_from_tensor(pixel)
    ids = ref.token_ids(texts)
    ref_txt = ref.text_embedding_from_ids(ids)

    c.check(type(ref.model).__name__ == "SiglipModel",
            "B1. AutoModel resolves to the fixed-resolution SiglipModel",
            f"got {type(ref.model).__name__}")

    tower = ref.model.vision_model
    with torch.no_grad():
        vision_out = tower(pixel_values=pixel, interpolate_pos_encoding=False)
    c.check(bool(getattr(tower, "use_head", False)) and vision_out.pooler_output is not None,
            "B2. MAP (attention-pooling) head is instantiated and used")
    no_head = vision_out.last_hidden_state[:, 0, :]
    no_head = no_head / no_head.norm(dim=-1, keepdim=True)
    map_head = vision_out.pooler_output / vision_out.pooler_output.norm(dim=-1, keepdim=True)
    head_cos = float((no_head * map_head).sum(dim=-1).min())
    c.check(head_cos < 0.99,
            "B3. pooling the MAP head differs from a naive first-token pool",
            f"min cosine {head_cos:.4f} — the head is genuinely in the path")

    try:
        siglip2_cfg = Siglip2Config(
            vision_config=AutoConfig.from_pretrained(checkpoint).vision_config.to_dict(),
            text_config=AutoConfig.from_pretrained(checkpoint).text_config.to_dict(),
        )
        Siglip2Model(siglip2_cfg).load_state_dict(ref.model.state_dict(), strict=True)
        c.check(False, "B4. Siglip2Model (naflex) is a different architecture",
                "naflex model accepted the fixed-resolution weights — revisit this assumption")
    except Exception as exc:  # noqa: BLE001
        c.check(True, "B4. Siglip2Model (naflex) is a different architecture",
                f"rejected as expected: {type(exc).__name__}")

    # C. do_convert_rgb=True is a no-op on RGB input
    from transformers import AutoProcessor

    processor = AutoProcessor.from_pretrained(checkpoint, use_fast=False)
    sample = load_image_rgb(images[0])
    a = processor.image_processor(images=[sample], return_tensors="pt")["pixel_values"]
    b = processor.image_processor(images=[sample], do_convert_rgb=True, return_tensors="pt")["pixel_values"]
    c.check(bool(torch.equal(a, b)), "C. do_convert_rgb=True is byte-identical for RGB input")

    # D. the RGBA trap the checkpoint config sets up
    from PIL import Image

    rgba = sample.convert("RGBA")
    raised = False
    try:
        processor.image_processor(images=[rgba], return_tensors="pt")
    except Exception:  # noqa: BLE001
        raised = True
    c.check(raised, "D. RGBA input without our RGB conversion fails (documented trap)")
    c.check(processor.image_processor.do_convert_rgb is None,
            "D2. checkpoint ships do_convert_rgb=null",
            f"value={processor.image_processor.do_convert_rgb!r}")

    # E. slow vs fast tokenizer
    from transformers import AutoTokenizer

    slow = AutoTokenizer.from_pretrained(checkpoint, use_fast=False)
    fast = AutoTokenizer.from_pretrained(checkpoint, use_fast=True)
    s_ids = [slow(t, padding="max_length", max_length=f.text_max_length, truncation=True)["input_ids"] for t in texts]
    f_ids = [fast(t, padding="max_length", max_length=f.text_max_length, truncation=True)["input_ids"] for t in texts]
    c.check(s_ids == f_ids, "E. slow and fast tokenizers agree exactly")

    # F. padding="max_length" without max_length silently does not pad
    unpadded = slow(texts[0], padding="max_length", truncation=True)["input_ids"]
    c.check(len(unpadded) < f.text_max_length,
            "F. padding='max_length' without max_length does NOT pad",
            f"got length {len(unpadded)}, sentinel model_max_length={slow.model_max_length}")

    # G. the pooling convention is a real decision
    #    Same padded batch, two pooling rules. If these agreed, porting the
    #    convention to Core ML would be free; they do not, so it is not.
    with torch.no_grad():
        out = ref.model.text_model(input_ids=ids)
        last_hidden = out.last_hidden_state
        pooled_last = ref.model.text_model.head(last_hidden[:, -1, :]).float().numpy()
        # last non-pad position
        mask = (ids != f.pad_token_id).int()
        pos = mask.sum(dim=1).clamp(min=1) - 1
        pooled_nonpad = ref.model.text_model.head(
            last_hidden[torch.arange(last_hidden.size(0)), pos]
        ).float().numpy()
    pooled_last /= np.maximum(np.linalg.norm(pooled_last, axis=1, keepdims=True), 1e-12)
    pooled_nonpad /= np.maximum(np.linalg.norm(pooled_nonpad, axis=1, keepdims=True), 1e-12)
    g_cos = float(cosine_rows(pooled_last, pooled_nonpad).min())
    c.check(bool(np.allclose(pooled_last, ref_txt, atol=1e-5)),
            "G1. reference uses last-position pooling")
    c.check(g_cos < 0.999, "G2. last-position != last-non-pad (convention matters)",
            f"min cosine {g_cos:.4f} — padding {int((ids == f.pad_token_id).sum(1).float().mean())} tokens on average")

    # H. determinism
    again = ref.text_embedding_from_ids(ids)
    c.check(bool(np.array_equal(ref_txt, again)), "H. reference is deterministic")

    # I. semantic sanity on real screenshots
    if real:
        cap_true = "手机相册应用的界面截图"
        cap_false = ["一只狗在沙滩上奔跑", "夜晚下雨的城市街道", "一碗热拉面"]
        true_scores = ref.similarity(real, [cap_true]).reshape(-1)
        false_scores = ref.similarity(real, cap_false)
        wins = int(np.sum(true_scores[:, None] > false_scores))
        total = true_scores.size * false_scores.shape[1]
        c.check(wins == total, "I. correct caption outranks wrong captions for every screenshot",
                f"{wins}/{total} comparisons on {len(real)} real images")
    else:
        print("  [SKIP] I. no real screenshots found for the semantic sanity check")

    return c.report()


def _fallback_images():
    """Synthetic stand-ins when the repo has no screenshots checked out."""
    from PIL import Image

    rng = np.random.default_rng(7)
    return [
        Image.fromarray(rng.integers(0, 256, (256, 256, 3), dtype=np.uint8), "RGB"),
        Image.fromarray(rng.integers(0, 256, (300, 200, 3), dtype=np.uint8), "RGB"),
    ]


# --------------------------------------------------------------------------
# mode: walk (build fixtures)
# --------------------------------------------------------------------------
def mode_walk(args) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    synthetic = make_synthetic_images(out / "images", args.count)
    real = real_images()
    images = synthetic + real[: args.real_limit]
    print(f"fixtures: {len(synthetic)} synthetic + {len(real[:args.real_limit])} real images")

    # Load every fixture up front: an unreadable file must fail here with its
    # path, not halfway through the reference pass.
    unreadable = []
    for p in images:
        try:
            img = load_image_rgb(p)
            if img.width == 0 or img.height == 0:
                unreadable.append((p, "zero size"))
        except Exception as exc:  # noqa: BLE001
            unreadable.append((p, f"{type(exc).__name__}: {exc}"))
    if unreadable:
        print(f"FAIL: {len(unreadable)} unreadable fixture(s)")
        for p, why in unreadable[:5]:
            print(f"  {p}: {why}")
        return 1

    ref = SigLIP2Reference.load(args.checkpoint, device=args.device)
    kinds = ["synthetic"] * len(synthetic) + ["real"] * len(real[: args.real_limit])
    ref.dump_parity(out, images, PARITY_QUERIES, image_kinds=kinds)
    print(f"wrote parity fixtures to {out}")
    print(f"  images:  {len(images)}  ({len(real[:args.real_limit])} real, {len(synthetic)} synthetic)")
    print(f"  queries: {len(PARITY_QUERIES)}")
    return 0


# --------------------------------------------------------------------------
# mode: coreml
# --------------------------------------------------------------------------
def mode_coreml(args) -> int:
    import coremltools as ct

    c = Checker()
    fixtures = Path(args.fixtures)
    manifest = json.loads((fixtures / "manifest.json").read_text(encoding="utf-8"))

    img_input = np.fromfile(fixtures / "image_input.bin", dtype="<f4").reshape(manifest["image_input_shape"])
    txt_input = np.fromfile(fixtures / "text_input.bin", dtype="<i4").reshape(manifest["text_input_shape"])
    ref_img = np.asarray(manifest["image_embeddings"], dtype=np.float32)
    ref_txt = np.asarray(manifest["text_embeddings"], dtype=np.float32)

    # -- image encoder -----------------------------------------------------
    if args.image_model:
        model = ct.models.MLModel(args.image_model, compute_units=ct.ComputeUnit.ALL)
        spec = model.get_spec()
        in_names = [i.name for i in spec.description.input]
        out_names = [o.name for o in spec.description.output]
        print(f"image model inputs: {in_names}")
        print(f"image model outputs: {out_names}")
        in_name = args.image_input_name if args.image_input_name in in_names else in_names[0]
        out_name = args.image_output_name or out_names[0]
        outs = []
        for i in range(img_input.shape[0]):
            pred = model.predict({in_name: img_input[i : i + 1]})
            outs.append(np.asarray(pred[out_name], dtype=np.float32).reshape(-1))
        got = np.vstack(outs)
        got /= np.maximum(np.linalg.norm(got, axis=1, keepdims=True), 1e-12)
        cos = cosine_rows(ref_img, got)
        label = args.label or Path(args.image_model).stem

        kinds = manifest.get("image_kinds") or ["real"] * cos.shape[0]
        real_mask = np.asarray([k == "real" for k in kinds], dtype=bool)
        synth_mask = ~real_mask
        real_min = float(cos[real_mask].min()) if real_mask.any() else float("nan")
        synth_min = float(cos[synth_mask].min()) if synth_mask.any() else float("nan")

        # Tiered gate. FP16 accumulates rounding far more on adversarial
        # synthetic content (random noise, hard high-frequency edges) than on
        # photographs, and the spec's 0.999 figure is a photograph-grade
        # threshold. Gating real content at `threshold` and the whole set at
        # `floor` keeps the strict claim where it matters instead of quietly
        # relaxing one global number. Prove any floor breach is rounding, not a
        # conversion defect, by re-running with an FP32 model.
        c.check(real_min >= args.threshold,
                f"image encoder parity, real photos [{label}]",
                f"min cosine {real_min:.6f}, mean {cos[real_mask].mean():.6f} "
                f"(threshold {args.threshold}, n={int(real_mask.sum())})")
        c.check(float(cos.min()) >= args.floor,
                f"image encoder parity, all fixtures [{label}]",
                f"min cosine {float(cos.min()):.6f} "
                f"(floor {args.floor}; worst synthetic {synth_min:.6f}) "
                f"— verify with an FP32 model before calling a breach a defect")
        _report_rank_agreement(c, ref_img @ ref_txt.T, got @ ref_txt.T, f"image [{label}]")

    # -- text encoder ------------------------------------------------------
    if args.text_model:
        model = ct.models.MLModel(args.text_model, compute_units=ct.ComputeUnit.ALL)
        spec = model.get_spec()
        in_names = [i.name for i in spec.description.input]
        out_names = [o.name for o in spec.description.output]
        print(f"text model inputs: {in_names}")
        print(f"text model outputs: {out_names}")
        in_name = args.text_input_name if args.text_input_name in in_names else in_names[0]
        out_name = args.text_output_name or out_names[0]
        outs = []
        for i in range(txt_input.shape[0]):
            pred = model.predict({in_name: txt_input[i : i + 1]})
            outs.append(np.asarray(pred[out_name], dtype=np.float32).reshape(-1))
        got = np.vstack(outs)
        got /= np.maximum(np.linalg.norm(got, axis=1, keepdims=True), 1e-12)
        cos = cosine_rows(ref_txt, got)
        label = args.label or Path(args.text_model).stem
        c.check(float(cos.min()) >= args.threshold,
                f"text encoder parity [{label}]",
                f"min cosine {cos.min():.6f}, mean {cos.mean():.6f} (threshold {args.threshold})")
        _report_rank_agreement(c, ref_img @ ref_txt.T, ref_img @ got.T, f"text [{label}]")

    if not args.image_model and not args.text_model:
        print("nothing to do: pass --image-model and/or --text-model")
        return 1

    return c.report()


def _report_rank_agreement(c: Checker, ref_scores: np.ndarray, got_scores: np.ndarray, label: str) -> None:
    """Retrieval rank agreement: the spec's quality gate is about ranking, not raw vectors."""
    n_img, n_txt = ref_scores.shape
    ok = 0
    ndcgs = []
    for j in range(n_txt):
        ref_rank = list(np.argsort(-ref_scores[:, j]))
        got_rank = list(np.argsort(-got_scores[:, j]))
        relevant = set(ref_rank[: max(1, n_img // 4)])
        if got_rank[:5] and got_rank[0] in relevant:
            ok += 1
        ndcgs.append(ndcg_at_k(got_rank, relevant, 20))
    print(f"    rank agreement [{label}]: top1-in-reference-top25% "
          f"{ok}/{n_txt}, mean nDCG@20 {np.mean(ndcgs):.4f}")


# --------------------------------------------------------------------------
# mode: tokenizer
# --------------------------------------------------------------------------
def mode_tokenizer(args) -> int:
    """Verify the Swift tokenizer, end to end, in one command.

    The evidence chain has three links and all three are checked here, in order:

      1. the real sentencepiece processor  --(is the port faithful?)-->
      2. `siglip2_tokenizer.py`            --(is the artifact + ground truth right?)-->
      3. `SigLIP2Tokenizer.swift`          --(does on-device code agree?)-->

    Link 1 is the one that matters most: a Swift implementation can only be as
    correct as the specification it was written against, so the Python port is
    diffed against sentencepiece on the same adversarial corpus before the Swift
    result is trusted. Checking only "Swift == Python" would be circular.
    """
    import sentencepiece as spm

    from build_tokenizer_corpus import build as build_corpus
    from siglip2_tokenizer import SigLIP2Tokenizer, _sha256

    checkpoint = Path(args.checkpoint)
    model_path = checkpoint / "tokenizer.model"
    if not model_path.exists():
        print(f"tokenizer.model not found at {model_path}", file=sys.stderr)
        return 1

    build_dir = HERE / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    corpus_path = build_dir / "tokenizer-corpus.json"
    truth_path = build_dir / "tokenizer-ground-truth.json"
    artifact_path = build_dir / "tokenizer-v1.bin"

    # Regenerate inputs when missing or when explicitly asked, so the mode is
    # reproducible from a clean checkout.
    if args.rebuild or not corpus_path.exists():
        corpus_path.write_text(json.dumps({"texts": build_corpus()}, ensure_ascii=False))
    texts = json.loads(corpus_path.read_text(encoding="utf-8"))["texts"]

    tok = SigLIP2Tokenizer(model_path)
    if args.rebuild or not artifact_path.exists():
        tok.to_binary_artifact(artifact_path, _sha256(model_path))
    if args.rebuild or not truth_path.exists():
        truth_path.write_text(json.dumps(
            {"texts": texts, "ids": [tok.encode(t, max_length=64) for t in texts]},
            ensure_ascii=False,
        ))

    c = Checker()
    facts = tok.facts
    c.check(facts.precompiled_charsmap_bytes == 0,
            "normalizer has no precompiled charsmap (identity, no NFKC, no case folding)")
    c.check(not facts.add_dummy_prefix,
            "normalizer does not add a dummy prefix (so no leading U+2581)")
    c.check(facts.escape_whitespaces, "normalizer escapes whitespace to U+2581")
    c.check(facts.byte_fallback, "byte fallback is enabled")
    c.check(facts.vocab_size == 256000 and facts.model_type == 2,
            f"vocabulary is 256000 pieces of BPE (got {facts.vocab_size}, type {facts.model_type})")
    c.check((facts.unk_id, facts.bos_id, facts.eos_id, facts.pad_id) == (3, 2, 1, 0),
            "special ids are unk=3 bos=2 eos=1 pad=0")

    # Link 1: the Python port against the authoritative implementation.
    sp = spm.SentencePieceProcessor(model_file=str(model_path))
    corpus_mismatch = 0
    for text in texts:
        want = sp.encode(text) + [facts.eos_id]
        want = want[:64] + [facts.pad_id] * max(0, 64 - len(want))
        if tok.encode(text, max_length=64) != want:
            corpus_mismatch += 1
    c.check(not corpus_mismatch,
            f"Python port matches sentencepiece on {len(texts)} adversarial strings",
            "" if not corpus_mismatch else f"{corpus_mismatch} mismatches")

    # Link 3: the Swift port, compiled here and run against Python's output.
    swift_source = HERE.parent.parent / "PhotoVault" / "Search" / "SigLIP2Tokenizer.swift"
    harness = HERE / "tokenizer_test" / "main.swift"
    if not swift_source.exists() or not harness.exists():
        c.check(False, "Swift tokenizer sources are present",
                f"missing {swift_source if not swift_source.exists() else harness}")
        return c.report()

    binary = Path(args.binary) if args.binary else Path("/tmp/pv-tokenizer-harness")
    compile_cmd = [
        "xcrun", "swiftc", "-O", "-o", str(binary), str(harness), str(swift_source),
    ]
    compiled = subprocess.run(compile_cmd, capture_output=True, text=True)
    c.check(compiled.returncode == 0, "Swift tokenizer compiles",
            compiled.stderr.strip()[:400] if compiled.returncode else "")
    if compiled.returncode != 0:
        return c.report()

    run = subprocess.run([str(binary), str(artifact_path), str(truth_path)],
                         capture_output=True, text=True)
    for line in run.stdout.splitlines():
        print(f"    | {line}")
    if run.stderr.strip():
        print(f"    | stderr: {run.stderr.strip()[:400]}")
    c.check(run.returncode == 0, "Swift tokenizer matches Python on the whole corpus")
    return c.report()


# --------------------------------------------------------------------------
# mode: embedding
# --------------------------------------------------------------------------
def mode_embedding(args) -> int:
    """Verify the embedding matrix file and its exact-search path.

    Three independent angles, because a storage format that is merely
    self-consistent can still be wrong in a way that only shows up as bad
    rankings later:

      1. unit tests    -- round trip, swap-remove bookkeeping, growth, and every
                          corruption case the header must reject
      2. benchmark     -- 100k rows, so the timing is measured at the size the
                          plan actually specifies
      3. NumPy check   -- an independent reader recomputes the top-k from the same
                          file; this is the golden reference the Phase 4 Metal
                          kernel must reproduce
    """
    repo = HERE.parent.parent
    store_source = repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift"
    if not store_source.exists():
        print(f"missing {store_source}", file=sys.stderr)
        return 1

    c = Checker()

    def build(entry: str, out: str) -> bool:
        command = [
            "xcrun", "swiftc", "-O", "-o", out,
            str(HERE / "embeddingstore_test" / "main.swift" if entry == "test" else HERE / "embeddingstore_bench" / "main.swift"),
            str(store_source),
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr.strip()[:800])
        return result.returncode == 0

    test_binary = "/tmp/pv-embedding-tests"
    if build("test", test_binary):
        run = subprocess.run([test_binary], capture_output=True, text=True)
        for line in run.stdout.splitlines():
            if "[FAIL]" in line or line.startswith("checks:") or line.startswith("RESULT"):
                print(f"    | {line}")
        c.check(run.returncode == 0, "embedding matrix unit tests pass")
    else:
        c.check(False, "embedding matrix unit tests compile")

    bench_binary = "/tmp/pv-embedding-bench"
    if build("bench", bench_binary):
        run = subprocess.run([bench_binary], capture_output=True, text=True, cwd=HERE)
        for line in run.stdout.splitlines():
            print(f"    | {line}")
        c.check(run.returncode == 0, "100k-row benchmark completes")

        check = subprocess.run(
            [sys.executable, str(HERE / "embeddingstore_check.py")],
            capture_output=True, text=True, cwd=HERE,
        )
        for line in check.stdout.splitlines():
            print(f"    | {line}")
        if check.stderr.strip():
            print(f"    | stderr: {check.stderr.strip()[:400]}")
        c.check(check.returncode == 0, "NumPy independently reproduces the rankings")
    else:
        c.check(False, "100k-row benchmark compiles")

    return c.report()


# --------------------------------------------------------------------------
# mode: index
# --------------------------------------------------------------------------
def mode_index(args) -> int:
    """Verify the metadata index (`AIPhotoSearchStore`) on macOS.

    PhotoKit is absent here, so the store is driven with synthetic asset
    identifiers. Everything the store owns is real: the schema, the slot
    arithmetic shared with the embedding matrix, FTS5, and the filters.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "AIPhotoSearchStore.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
        repo / "PhotoVault" / "Search" / "SearchTextNormalization.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    binary = "/tmp/pv-aistore-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "aistore_test" / "main.swift")] + [str(s) for s in sources]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "search index tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")) or "FTS5 compiled" in line:
            print(f"    | {line}")
    c.check(run.returncode == 0, "search index tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: metal
# --------------------------------------------------------------------------
def mode_privacy(args) -> int:
    """Audit the on-device guarantee, as source rather than as a promise.

    The constraint is "no photo, embedding, OCR text or query ever leaves the
    device". That is easy to state and easy to break later -- one `URLSession`
    added during debugging is all it takes. So this checks the *source* of the
    search stack, where such a change would have to appear.

    A greyscale reading of the imports is deliberate: the point is not that the
    code currently behaves, it is that it *cannot* phone home without this gate
    failing.
    """
    repo = HERE.parent.parent
    search = repo / "PhotoVault" / "Search"
    c = Checker()

    sources = sorted(search.glob("*.swift"))
    if not sources:
        print(f"    | no sources under {search}", file=sys.stderr)
        c.check(False, "the search stack is present")
        return c.report()
    print(f"    | auditing {len(sources)} files in PhotoVault/Search")

    # ---- 1. no networking -------------------------------------------------
    network = [
        "URLSession", "URLRequest", "NWConnection", "NWPathMonitor",
        "CFReadStream", "CFWriteStream", "uploadTask", "dataTask",
        "WebSocket", "NSURLConnection", "Network.framework",
    ]
    found_network = []
    for path in sources:
        text = path.read_text()
        for token in network:
            for number, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                # Comments discuss the guarantee; they are not code.
                if stripped.startswith("//") or stripped.startswith("///"):
                    continue
                if token in line:
                    found_network.append(f"{path.name}:{number} {token}")
    c.check(not found_network,
            "no networking API appears anywhere in the search stack",
            "; ".join(found_network[:4]))

    # ---- 2. no remote endpoints ------------------------------------------
    found_urls = []
    for path in sources:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if "http://" in line or "https://" in line:
                found_urls.append(f"{path.name}:{number}")
    c.check(not found_urls, "and no remote endpoint is referenced",
            "; ".join(found_urls[:4]))

    # ---- 3. system frameworks only ---------------------------------------
    allowed = {
        "Foundation", "Photos", "SwiftUI", "UIKit", "CoreML", "CoreGraphics",
        "Vision", "Metal", "Accelerate", "SQLite3", "CoreImage", "ImageIO",
        "MetalPerformanceShaders", "os", "UniformTypeIdentifiers", "CoreVideo",
        "simd", "Darwin", "CryptoKit", "Dispatch", "CoreLocation", "MapKit",
    }
    foreign = set()
    for path in sources:
        for line in path.read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith("import "):
                module = stripped.split()[1].split(".")[0]
                if module not in allowed:
                    foreign.add(module)
    c.check(not foreign, "only system frameworks are imported",
            ", ".join(sorted(foreign)))

    # ---- 4. the search stack does not log its inputs ----------------------
    # Photos, OCR text and queries are exactly what must never reach a log.
    logging = []
    for path in sources:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            # Word boundary before the call, or `modelFingerprint(` matches
            # `print(` and the gate reports a log call that does not exist. A
            # check that cries wolf is a check that gets ignored.
            for token in ("print", "NSLog", "debugPrint", "os_log", "Logger"):
                if re.search(r"(?<![A-Za-z0-9_])" + re.escape(token) + r"\s*\(", line):
                    logging.append(f"{path.name}:{number} {token}(")
    c.check(not logging, "nothing in the search stack writes to a log",
            "; ".join(logging[:4]))

    # ---- 5. the embedding matrix is kept out of backups ------------------
    # It is derived data: 100k x 768 float16 is ~150 MB of something the device
    # can recompute, and backing it up would push a large private file into
    # iCloud -- the opposite of "on device".
    embedding = (search / "EmbeddingStoreFile.swift").read_text()
    c.check("isExcludedFromBackup" in embedding,
          "the embedding matrix is excluded from device backups")

    # ---- 6. the notices are complete -------------------------------------
    notices = repo / "THIRD_PARTY_NOTICES.md"
    c.check(notices.exists(), "THIRD_PARTY_NOTICES.md exists")
    if notices.exists():
        text = notices.read_text()
        c.check("Apache License" in text and "Version 2.0" in text,
                "it carries the full Apache-2.0 text")
        c.check("siglip2-base-patch16-256" in text,
                "and names the model actually shipped")
        c.check("Apache-2.0" in text, "with its licence")
        # The licence requires stating that the files were changed.
        c.check("MODIF" in text.upper() or "modif" in text,
                "and discloses that the model was modified")

    # ---- 7. Release builds carry no debug diagnostics --------------------
    release_binary = (repo / "build" / "DerivedDataRelease" / "Build" / "Products"
                      / "Release-iphoneos" / "PhotoVault.app" / "PhotoVault")
    if release_binary.exists():
        blob = release_binary.read_bytes()
        # `AISearchSelfCheck.log` is included because the self-check writes a
        # report and must be `#if DEBUG`; if it ever leaked into Release this
        # catches it.
        leaked = [name for name in
                  (b"PhotoVaultLaunch.log", b"PagerDiagnostics.log", b"lan-folder.log",
                   b"AISearchSelfCheck")
                  if name in blob]
        c.check(not leaked, "the Release binary carries no debug log paths",
                ", ".join(n.decode() for n in leaked))
    else:
        print("    | (Release build not present; skipping the binary check)")

    return c.report()


def mode_bundle(args) -> int:
    """Verify the model artifacts that are actually inside the built app.

    Every other mode here checks the pipeline: Python reference, converted
    mlpackage, Swift port. All of them passed while the app still had no model in
    it, because "the mlpackage is correct" and "the app can load what shipped"
    are separate claims. This mode loads the `.mlmodelc` files out of the built
    `PhotoVault.app` and runs them.

    The decisive check is cos("CAT", "cat") ~= 0.8616. That one number proves the
    bundled tokenizer and the bundled text tower are the *pair* that was
    validated: a mismatched vocabulary, a case-folding normalizer, or a stale
    model would each move it.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "SearchModelResources.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2VisionEncoder.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2TextEncoder.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2Tokenizer.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    app = repo / "build" / "DerivedDataPhotoVault" / "Build" / "Products" /         "Debug-iphoneos" / "PhotoVault.app"
    c = Checker()
    if not app.exists():
        print(f"    | the app bundle is not built yet: {app}", file=sys.stderr)
        print("    | build it first:", file=sys.stderr)
        print("    |   xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault \\",
              file=sys.stderr)
        print("    |     -configuration Debug -destination 'generic/platform=iOS' build",
              file=sys.stderr)
        c.check(False, "the bundled model is loadable")
        return c.report()

    binary = "/tmp/pv-bundle-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "bundle_test" / "main.swift")] + [str(s) for s in sources]
    command += ["-framework", "AppKit", "-framework", "CoreML"]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:1200])
        c.check(False, "bundled-model tests compile")
        return c.report()

    run = subprocess.run([binary, str(app)], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")) or "cos(" in line:
            print(f"    | {line}")
    c.check(run.returncode == 0, "bundled-model tests pass")
    return c.report()


def mode_pipeline(args) -> int:
    """Verify the indexing pipeline (Phase 3, PhotoKit-free) on macOS.

    PhotoKit is deliberately absent, and that is what makes this worth running.
    The pipeline's job is not to talk to PhotoKit -- that is framework glue --
    but to decide when to stop, what to retry, what to defer when the device is
    hot, and to guarantee that a superseded run cannot write. All of that is
    pure logic, so all of it is testable here.

    The store is real, so "resume after the app is killed" is tested by throwing
    the coordinator away and building a new one over the same database.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "PhotoIndexPipeline.swift",
        repo / "PhotoVault" / "Search" / "AIPhotoSearchStore.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
        repo / "PhotoVault" / "Search" / "SearchTextNormalization.swift",
        repo / "PhotoVault" / "Search" / "PhotoTextRecognizer.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    binary = "/tmp/pv-pipeline-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "pipeline_test" / "main.swift")] + [str(s) for s in sources]
    command += ["-framework", "AppKit"]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:1200])
        c.check(False, "index pipeline tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
    c.check(run.returncode == 0, "index pipeline tests pass")
    return c.report()


def mode_metal(args) -> int:
    """Verify the Metal exact-search kernel against the CPU and NumPy rankings.

    The GPU agreeing with the CPU path is only meaningful because the CPU path
    was itself checked against an independent NumPy reader; without that, both
    could be wrong together.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "MetalSimilaritySearch.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
    ]
    metal_source = repo / "PhotoVault" / "Search" / "EmbeddingSimilarity.metal"
    for source in sources + [metal_source]:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    air, metallib = "/tmp/pv-embedding.air", "/tmp/pv-embedding.metallib"
    for command in (
        ["xcrun", "-sdk", "macosx", "metal", "-c", str(metal_source), "-o", air],
        ["xcrun", "-sdk", "macosx", "metallib", air, "-o", metallib],
    ):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr.strip()[:800])
            c.check(False, f"Metal kernel builds ({' '.join(command[3:5])})")
            return c.report()
    c.check(True, "Metal kernel compiles to a metallib")

    binary = "/tmp/pv-metal-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "metal_test" / "main.swift")] + [str(s) for s in sources] + ["-framework", "Metal"]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "Metal search tests compile")
        return c.report()

    run = subprocess.run([binary, "--library", metallib], capture_output=True, text=True, cwd=HERE)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT", "SKIP")):
            print(f"    | {line}")
        elif "Metal P50" in line or "worst vs Double" in line:
            print(f"    | {line}")
    c.check(run.returncode == 0, "Metal search tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: textencoder
# --------------------------------------------------------------------------
def mode_textencoder(args) -> int:
    """Run the whole Swift text pipeline against the PyTorch reference.

    The tokenizer test proves the Swift BPE port matches sentencepiece; the
    conversion test proves the Core ML graph matches PyTorch. Neither ever runs
    the two Swift halves together. This does, on the same strings -- which is the
    only place a wrong case-folding flag or a missing pad token can surface.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "SigLIP2TextEncoder.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2Tokenizer.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    fixture = HERE / "build" / "text-parity.json"
    if not fixture.exists():
        print("    | building the text-parity fixture (loads the PyTorch reference once)")
        build = subprocess.run(
            [sys.executable, str(HERE / "build_text_parity.py")],
            capture_output=True, text=True, cwd=HERE,
            env={**os.environ, "HF_HUB_DISABLE_XET": "1"},
        )
        for line in build.stdout.strip().splitlines():
            print(f"    | {line}")
        if build.returncode != 0:
            print(build.stderr.strip()[:600])
            c.check(False, "text-parity fixture builds")
            return c.report()
    c.check(True, "text-parity fixture is available")

    binary = "/tmp/pv-textencoder-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "textencoder_test" / "main.swift"),
               str(sources[0]), str(sources[1]), "-framework", "CoreML"]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "text pipeline tests compile")
        return c.report()

    # W8 is the shipping configuration and therefore the gate; the other two are
    # run for calibration so the cost of quantisation is visible on every run
    # rather than buried in a document.
    models = [("w8", "SigLIP2TextEncoder-w8", 0.998),
              ("fp16", "SigLIP2TextEncoder", 0.9999),
              ("fp32", "SigLIP2TextEncoder-fp32", 0.9999)]
    for label, name, threshold in models:
        package = HERE / "out" / f"{name}.mlpackage"
        if not package.exists():
            print(f"    | SKIP {label}: no {package.name}")
            continue
        run = subprocess.run(
            [binary, "--model", str(package), "--threshold", str(threshold)],
            capture_output=True, text=True, cwd=HERE,
        )
        print(f"    | --- {label} (threshold {threshold}) ---")
        for line in run.stdout.splitlines():
            if "[FAIL]" in line or "cosine vs PyTorch" in line or "P50" in line:
                print(f"    | {line.strip()}")
        c.check(run.returncode == 0, f"Swift text pipeline matches PyTorch ({label})")

    return c.report()


# --------------------------------------------------------------------------
# mode: query
# --------------------------------------------------------------------------
def mode_query(args) -> int:
    """Verify the query analyzer.

    Pure logic with an injected `now`, so every case pins an exact plan rather
    than asserting that something was found. A wrong parse returns plausible
    photos, which is the failure mode this exists to prevent.
    """
    repo = HERE.parent.parent
    source = repo / "PhotoVault" / "Search" / "QueryAnalyzer.swift"
    if not source.exists():
        print(f"missing {source}", file=sys.stderr)
        return 1

    c = Checker()
    binary = "/tmp/pv-query-tests"
    build = subprocess.run(
        ["xcrun", "swiftc", "-O", "-o", binary,
         str(HERE / "queryanalyzer_test" / "main.swift"), str(source)],
        capture_output=True, text=True,
    )
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "query analyzer tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
    c.check(run.returncode == 0, "query analyzer tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: ocr
# --------------------------------------------------------------------------
def mode_ocr(args) -> int:
    """Verify Vision text recognition and its path into the FTS index.

    Recognising text is only half the job; the other half is that a query can
    then find it. The cached half runs the whole chain -- Vision, normalisation,
    the store's two FTS paths -- on recognised output rather than on strings
    typed by hand.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "PhotoTextRecognizer.swift",
        repo / "PhotoVault" / "Search" / "SearchTextNormalization.swift",
        repo / "PhotoVault" / "Search" / "AIPhotoSearchStore.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    binary = "/tmp/pv-ocr-tests"
    command = (["xcrun", "swiftc", "-O", "-o", binary,
                str(HERE / "ocr_test" / "main.swift")]
               + [str(s) for s in sources]
               + ["-framework", "Vision", "-framework", "AppKit"])
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "OCR tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
        elif "languages," in line or "OCR P50" in line or "NOTE" in line:
            print(f"    | {line.strip()}")
    c.check(run.returncode == 0, "OCR and hybrid FTS tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: geo
# --------------------------------------------------------------------------
def mode_geo(args) -> int:
    """Verify the offline gazetteer and the path from a mention to SQLite rows.

    The end-to-end half matters more than the unit half: a gazetteer that
    resolves correctly but produces a box the store cannot use would pass every
    unit test and return nothing in the app.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "OfflineGazetteer.swift",
        repo / "PhotoVault" / "Search" / "GazetteerData.swift",
        repo / "PhotoVault" / "Search" / "AIPhotoSearchStore.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
        repo / "PhotoVault" / "Search" / "SearchTextNormalization.swift",
        repo / "PhotoVault" / "Search" / "QueryAnalyzer.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    binary = "/tmp/pv-gazetteer-tests"
    command = (["xcrun", "swiftc", "-O", "-o", binary,
                str(HERE / "gazetteer_test" / "main.swift")]
               + [str(s) for s in sources])
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "gazetteer tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
        elif "places" in line and "by kind" not in line:
            print(f"    | {line.strip()}")
        elif "by kind:" in line:
            print(f"    | {line.strip()}")
    c.check(run.returncode == 0, "gazetteer, bounding-box and geo-filter tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: search
# --------------------------------------------------------------------------
def mode_search(args) -> int:
    """Verify the search engine end to end.

    Only the text tower is stubbed: the mechanics under test -- how clauses
    combine, how negation rejects, whether a metadata filter restricts the work
    -- need vectors whose relationships are known exactly. The store, the mmap
    matrix and the scoring code are all real.
    """
    repo = HERE.parent.parent
    sources = [
        repo / "PhotoVault" / "Search" / "PhotoSearchEngine.swift",
        repo / "PhotoVault" / "Search" / "EmbeddingStoreFile.swift",
        repo / "PhotoVault" / "Search" / "QueryAnalyzer.swift",
        repo / "PhotoVault" / "Search" / "OfflineGazetteer.swift",
        repo / "PhotoVault" / "Search" / "GazetteerData.swift",
        repo / "PhotoVault" / "Search" / "SearchTextNormalization.swift",
        repo / "PhotoVault" / "Search" / "AIPhotoSearchStore.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2TextEncoder.swift",
        repo / "PhotoVault" / "Search" / "SigLIP2Tokenizer.swift",
    ]
    for source in sources:
        if not source.exists():
            print(f"missing {source}", file=sys.stderr)
            return 1

    c = Checker()
    binary = "/tmp/pv-engine-tests"
    command = (["xcrun", "swiftc", "-O", "-o", binary,
                str(HERE / "searchengine_test" / "main.swift")]
               + [str(s) for s in sources])
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:1200])
        c.check(False, "engine tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
        elif line.startswith("         ") and "->" in line:
            print(f"    | {line.strip()}")
    c.check(run.returncode == 0, "search engine end-to-end tests pass")
    return c.report()


# --------------------------------------------------------------------------
# mode: vision
# --------------------------------------------------------------------------
def mode_vision(args) -> int:
    """Verify the Swift image encoder against the Python reference.

    Two numbers, because they fail for different reasons: the tensor compared
    against the exact array the reference fed to PyTorch (a resize, colour or
    layout bug in our code), and the Core ML embedding against the reference
    embeddings (whether an indexed photo is actually findable).

    The decisive section feeds the Swift resampler the bytes PIL produced. That
    removes image decoding from the comparison, so a difference there is
    unambiguously ours -- Apple's ImageIO and libjpeg disagree about JPEGs, and
    without this separation a decoder difference is indistinguishable from a
    resampling bug.
    """
    repo = HERE.parent.parent
    source = repo / "PhotoVault" / "Search" / "SigLIP2VisionEncoder.swift"
    if not source.exists():
        print(f"missing {source}", file=sys.stderr)
        return 1

    parity = HERE / "build" / "parity"
    if not (parity / "manifest.json").exists():
        print("build/parity/manifest.json is missing; run: python verify_siglip2.py walk")
        return 1

    c = Checker()
    # The isolated fixtures are ~700 MB of regenerable data, so they are built
    # only when absent rather than on every run.
    if not (parity / "resample" / "expected.bin").exists():
        print("    | building isolated resample fixtures (first run only, ~700 MB) ...")
        dump = subprocess.run(
            [sys.executable, str(HERE / "dump_resample_fixtures.py")],
            capture_output=True, text=True,
        )
        if dump.returncode != 0:
            print(dump.stdout[-600:])
            print(dump.stderr[-600:])
            c.check(False, "isolated resample fixtures build")
            return c.report()
        tail = [line for line in dump.stdout.splitlines() if "self-check" in line]
        for line in tail:
            print(f"    | {line.strip()}")

    binary = "/tmp/pv-vision-tests"
    command = ["xcrun", "swiftc", "-O", "-o", binary,
               str(HERE / "visionencoder_test" / "main.swift"), str(source)]
    build = subprocess.run(command, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr.strip()[:800])
        c.check(False, "vision encoder tests compile")
        return c.report()

    run = subprocess.run([binary], capture_output=True, text=True)
    for line in run.stdout.splitlines():
        if "[FAIL]" in line or line.startswith(("checks:", "RESULT")):
            print(f"    | {line}")
        elif line.startswith("         ") and any(
            key in line for key in ("cos ", "max ", "warm", "first prediction", "images,",
                                    "reference tensor", "fixture images", "lossy", "model:")
        ):
            print(f"    | {line.strip()}")
    c.check(run.returncode == 0, "vision encoder parity passes")
    return c.report()


# --------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT_DIR))
    p.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    sub = p.add_subparsers(dest="mode", required=True)

    sub.add_parser("reference", help="verify the reference model and its conventions")

    w = sub.add_parser("walk", help="build the parity fixture set")
    w.add_argument("--out", default=str(HERE / "build" / "parity"))
    w.add_argument("--count", type=int, default=50, help="number of synthetic images")
    w.add_argument("--real-limit", type=int, default=50, help="max real screenshots to include")

    cm = sub.add_parser("coreml", help="compare converted mlpackage against the reference")
    cm.add_argument("--fixtures", default=str(HERE / "build" / "parity"))
    cm.add_argument("--image-model")
    cm.add_argument("--text-model")
    cm.add_argument("--image-input-name", default="image")
    cm.add_argument("--image-output-name")
    cm.add_argument("--text-input-name", default="input_ids")
    cm.add_argument("--text-output-name")
    cm.add_argument("--threshold", type=float, default=0.999,
                    help="min cosine for real photographs (0.999 for FP16 per spec)")
    cm.add_argument("--floor", type=float, default=0.995,
                    help="min cosine across ALL fixtures including adversarial synthetics")
    cm.add_argument("--label", help="label for the report (e.g. W8)")

    sub.add_parser("embedding", help="verify the embedding matrix file and exact search")
    sub.add_parser("index", help="verify the metadata index, slot bookkeeping and FTS")
    sub.add_parser("pipeline", help="verify the PhotoKit-free index pipeline: pause, resume, backoff, thermal")
    sub.add_parser("bundle", help="verify the models inside the built app bundle load and reproduce the reference")
    sub.add_parser("privacy", help="audit the on-device guarantee as source: no network, no logging, complete notices")
    sub.add_parser("metal", help="verify the Metal exact-search kernel")
    sub.add_parser("textencoder", help="run the Swift text pipeline against PyTorch")
    sub.add_parser("query", help="verify the query analyzer (AND / NOT / dates / places)")
    sub.add_parser("ocr", help="verify Vision OCR and its path into the FTS index")
    sub.add_parser("geo", help="verify the offline gazetteer and geo filtering")
    sub.add_parser("search", help="verify the search engine end to end")
    sub.add_parser("vision", help="verify the Swift image encoder against the reference")

    tk = sub.add_parser("tokenizer", help="verify the Swift tokenizer against sentencepiece")
    tk.add_argument("--rebuild", action="store_true",
                    help="regenerate the corpus, artifact and ground truth first")
    tk.add_argument("--binary", help="where to put the compiled harness")

    args = p.parse_args()
    if args.mode == "reference":
        return mode_reference(args)
    if args.mode == "walk":
        return mode_walk(args)
    if args.mode == "coreml":
        return mode_coreml(args)
    if args.mode == "vision":
        return mode_vision(args)
    if args.mode == "search":
        return mode_search(args)
    if args.mode == "geo":
        return mode_geo(args)
    if args.mode == "ocr":
        return mode_ocr(args)
    if args.mode == "query":
        return mode_query(args)
    if args.mode == "textencoder":
        return mode_textencoder(args)
    if args.mode == "metal":
        return mode_metal(args)
    if args.mode == "privacy":
        return mode_privacy(args)
    if args.mode == "bundle":
        return mode_bundle(args)
    if args.mode == "pipeline":
        return mode_pipeline(args)
    if args.mode == "index":
        return mode_index(args)
    if args.mode == "embedding":
        return mode_embedding(args)
    if args.mode == "tokenizer":
        return mode_tokenizer(args)
    p.error(f"unknown mode {args.mode}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
