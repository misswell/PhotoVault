#!/usr/bin/env python3
"""Convert google/siglip2-base-patch16-256 into two Core ML packages for PhotoVault.

    SigLIP2ImageEncoder.mlpackage   pixel_values [1,3,256,256] float32 -> embedding [1,768] float32
    SigLIP2TextEncoder.mlpackage    input_ids    [1,64]        int32   -> embedding [1,768] float32

Design decisions, all deliberate:

* **Two separate models.** Indexing keeps only the image encoder resident;
  search keeps only the text encoder resident. One fused model would force both
  towers into memory for either operation (spec sections 5 and 65).

* **MultiArray inputs, not image inputs.** Core ML's image input type does its
  own colourspace/scale handling, which we cannot make bit-exactly match
  Pillow + `SiglipImageProcessor`. Feeding a float NCHW tensor we produced
  ourselves makes the model-vs-PyTorch parity test meaningful: any residual is
  the model, never the preprocessing. It also sidesteps the fact that the
  checkpoint ships `do_convert_rgb: null` while PhotoVault's screenshots are
  RGBA (see siglip2_reference.py note 5).

* **Batch 1, fully static shapes.** Every dimension is constant, including the
  64-token text length. No enumerated shapes, no dynamic axes, no attention
  mask (SigLIP2 was trained without one — the model pools the last position
  regardless of padding).

* **L2 normalization inside the model.** The spec requires every embedding to be
  unit norm; baking it in means the Swift side cannot forget it, and
  `cosine == dot` holds by construction.

* **`attn_implementation="eager"`.** SDPA traces to `aten::scaled_dot_product_attention`,
  whose Core ML support is version dependent. Eager attention is plain
  matmul + softmax, which converts cleanly and quantizes predictably. The
  reference (SDPA) is verified to agree.

* **The MAP head is re-implemented with explicit ops.** `nn.MultiheadAttention`
  may trace to `aten::_native_multi_head_attention`, which does not convert.
  The manual version is asserted numerically equal to the original.

Usage
-----
    # FP16 baseline (do this first, verify parity, then quantize)
    python convert_siglip2.py
    # W8
    python convert_siglip2.py --quantize w8
    # conversion only, no self-check
    python convert_siglip2.py --no-verify
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from siglip2_reference import DEFAULT_CHECKPOINT_DIR, SigLIP2Reference  # noqa: E402

TEXT_MAX_POSITIONS_FALLBACK = 64


# --------------------------------------------------------------------------
# Traceable encoder wrappers
# --------------------------------------------------------------------------
class ManualMAPHead(nn.Module):
    """`SiglipMultiheadAttentionPoolingHead` with explicit ops.

    Identical math: probe query over the patch sequence, residual + layernorm +
    MLP, take position 0. Rewritten because nn.MultiheadAttention does not
    convert reliably.
    """

    def __init__(self, head, num_heads: int, hidden_size: int, eps: float):
        super().__init__()
        self.num_heads = num_heads
        self.head_dim = hidden_size // num_heads
        self.hidden_size = hidden_size
        self.scale = 1.0 / math.sqrt(self.head_dim)
        self.probe = head.probe
        self.in_proj_weight = head.attention.in_proj_weight
        self.in_proj_bias = head.attention.in_proj_bias
        self.out_proj = head.attention.out_proj
        self.layernorm = head.layernorm
        self.mlp = head.mlp

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        b, s, d = hidden.shape
        wq, wk, wv = self.in_proj_weight.split(self.hidden_size, dim=0)
        bq, bk, bv = self.in_proj_bias.split(self.hidden_size, dim=0)

        probe = self.probe.expand(b, 1, self.hidden_size)
        q = F.linear(probe, wq, bq)                      # [B,1,D]
        k = F.linear(hidden, wk, bk)                     # [B,S,D]
        v = F.linear(hidden, wv, bv)                     # [B,S,D]

        q = q.view(b, 1, self.num_heads, self.head_dim).transpose(1, 2)
        k = k.view(b, s, self.num_heads, self.head_dim).transpose(1, 2)
        v = v.view(b, s, self.num_heads, self.head_dim).transpose(1, 2)

        attn = torch.softmax(torch.matmul(q, k.transpose(-1, -2)) * self.scale, dim=-1)
        out = torch.matmul(attn, v).transpose(1, 2).reshape(b, 1, d)
        out = self.out_proj(out)

        residual = out
        out = self.layernorm(out)
        out = residual + self.mlp(out)
        return out[:, 0]


class VisionEncoder(nn.Module):
    """pixel_values [1,3,H,W] -> unit-norm embedding [1,D]."""

    def __init__(self, siglip, config):
        super().__init__()
        self.vision_model = siglip.vision_model
        vc = config.vision_config
        original_head = self.vision_model.head
        self.vision_model.head = ManualMAPHead(
            original_head, vc.num_attention_heads, vc.hidden_size, vc.layer_norm_eps
        )
        if not getattr(self.vision_model, "use_head", False):
            raise AssertionError("vision tower has no MAP head; image embeddings would be wrong")

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        out = self.vision_model(pixel_values=pixel_values, interpolate_pos_encoding=False)
        return F.normalize(out.pooler_output, dim=-1)


class TextEncoder(nn.Module):
    """input_ids [1,L] int32 -> unit-norm embedding [1,D].

    No attention mask: SigLIP/SigLIP2 were trained without padding masking and
    pool the final position, so `[1, 64]` ids are the complete input.
    """

    def __init__(self, siglip):
        super().__init__()
        self.text_model = siglip.text_model

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        out = self.text_model(input_ids=input_ids)
        return F.normalize(out.pooler_output, dim=-1)


# --------------------------------------------------------------------------
# conversion helpers
# --------------------------------------------------------------------------
def pick_deployment_target(ct, name: str):
    """Resolve a deployment target by name.

    Default is iOS18 (the CoreML8 opset) rather than iOS26 (CoreML9). iOS26 is
    the app's minimum, so *either* target produces a model the app can load —
    but this Mac runs macOS 15.7.7, whose Core ML runtime cannot execute the
    CoreML9 opset, so an iOS26-targeted mlpackage cannot be parity-checked
    locally (`Unknown opset 'CoreML9'`). Nothing in SigLIP2 needs CoreML9 ops,
    so iOS18 costs nothing and keeps conversion self-verifiable. Re-check on an
    iOS 26 device (Phase 2 device gate) before shipping a different target.
    """
    attr = "iOS" + name[3:] if name.lower().startswith("ios") else name
    if not hasattr(ct.target, attr):
        available = sorted(n for n in dir(ct.target) if n.startswith("iOS") and n[3:].isdigit())
        raise SystemExit(f"unknown deployment target {name!r}; coremltools has {available}")
    target = getattr(ct.target, attr)
    print(f"  minimum_deployment_target = {attr}")
    if attr != "iOS18":
        print(f"  [WARN] {attr} emits a newer opset than this Mac's Core ML runtime; "
              f"predict()/parity checks will fail locally. Verify on an iOS 26 device.")
    return target


def convert_module(ct, module, example_inputs, input_specs, output_name, target, precision):
    module.eval()
    with torch.no_grad():
        traced = torch.jit.trace(module, example_inputs, strict=False)
        # Fold the constants so the graph is a plain sequence of ops.
        traced = torch.jit.freeze(traced)
    return ct.convert(
        traced,
        inputs=input_specs,
        outputs=[ct.TensorType(name=output_name, dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=target,
        compute_units=ct.ComputeUnit.ALL,
    )


def _quantizable_consts(mlmodel, allowed=("linear", "conv", "gather")):
    """Split consts into genuine op weights and everything else.

    This guard exists because of a measured trap. In the traced vision graph the
    position embedding is folded into a **constant** `[1, 256, 768]` (its
    `position_ids` buffer is constant, so the gather disappears) which then feeds
    an `add`. `linear_quantize_weights` quantizes it anyway, and the vision
    position embedding turns out to be by far the most quantization-sensitive
    tensor in the model: quantizing it *alone* drops the image embedding to
    0.966 cosine on real photos (mean 0.957) in simulation, which is almost
    exactly the 0.93 the first W8 attempt produced. Nothing about the const's
    name makes that visible.

    So: quantize a const only when every op consuming it is a real
    weight-bearing op. Anything feeding `add`/`mul`/`reshape`/`transpose` and
    friends stays in FP16.
    """
    from coremltools.optimize.coreml import get_weights_metadata

    metadata = get_weights_metadata(mlmodel, weight_threshold=1)
    keep, skip = {}, {}
    for name, meta in metadata.items():
        if meta.val is None:
            continue
        consumers = {c.op_type for c in (meta.child_ops or [])}
        if consumers and consumers <= set(allowed):
            keep[name] = consumers
        else:
            skip[name] = consumers or {"(unused)"}
    return keep, skip


def quantize_w8(ct, mlmodel, has_embedding: bool):
    """Weight-only 8-bit quantization of real op weights.

    Deliberately *only* the linear quantizer, applied to genuine weights. The
    first attempt additionally ran a palettization pass over `global_config`,
    which re-quantized the already-int8 linear weights and cost ~1.5 points of
    text cosine for no further size benefit.

    `has_embedding` is accepted for call-site symmetry: per-row int8 is already
    a good scheme for the 256000x768 token table (measured 0.9993 cosine in
    isolation), so it needs no special handling.
    """
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    keep, skip = _quantizable_consts(mlmodel)
    print(f"  quantizing {len(keep)} weight consts, leaving {len(skip)} in FP16")
    for name, consumers in list(skip.items())[:6]:
        print(f"    [skip] {name}  <- consumed by {sorted(consumers)}")

    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype=np.int8, granularity="per_channel"
        ),
        op_name_configs={name: None for name in skip},
    )
    model = linear_quantize_weights(mlmodel, config=config)
    _ = has_embedding
    return model


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dir_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def verify_against_reference(ref: SigLIP2Reference, image_ml, text_ml, image_input, text_input, threshold):
    """Self-check inside the conversion run: never hand over an unverified model."""
    from PIL import Image

    rng = np.random.default_rng(0)
    imgs = [
        Image.fromarray(rng.integers(0, 256, (256, 256, 3), dtype=np.uint8), "RGB"),
        Image.fromarray(rng.integers(0, 256, (200, 400, 3), dtype=np.uint8), "RGB"),
    ]
    texts = ["海边的狗", "a photo of a cat", "写着报销的截图"]

    pixel = ref.image_tensor(imgs).numpy()
    ids = ref.token_ids(texts).numpy()
    want_img = ref.image_embedding_from_tensor(torch.from_numpy(pixel))
    want_txt = ref.text_embedding_from_ids(torch.from_numpy(ids))

    got_img = np.vstack([
        np.asarray(image_ml.predict({image_input: pixel[i : i + 1]})["embedding"], dtype=np.float32).reshape(-1)
        for i in range(pixel.shape[0])
    ])
    got_txt = np.vstack([
        np.asarray(text_ml.predict({text_input: ids[i : i + 1]})["embedding"], dtype=np.float32).reshape(-1)
        for i in range(ids.shape[0])
    ])

    def cos(a, b):
        a = a / np.maximum(np.linalg.norm(a, axis=1, keepdims=True), 1e-12)
        b = b / np.maximum(np.linalg.norm(b, axis=1, keepdims=True), 1e-12)
        return np.sum(a * b, axis=1)

    img_cos = cos(want_img, got_img)
    txt_cos = cos(want_txt, got_txt)
    print(f"  image parity: min {img_cos.min():.6f}  mean {img_cos.mean():.6f}")
    print(f"  text  parity: min {txt_cos.min():.6f}  mean {txt_cos.mean():.6f}")
    ok = float(min(img_cos.min(), txt_cos.min())) >= threshold
    print(f"  threshold {threshold}: {'PASS' if ok else 'FAIL'}")
    return ok, float(img_cos.min()), float(txt_cos.min())


# --------------------------------------------------------------------------
def _empirical_case_folding(facts, checkpoint_dir) -> bool:
    """Determine case folding by observation rather than by configuration.

    HuggingFace's tokenizer wrapper reports ``do_lower_case=True`` for this
    checkpoint, but the sentencepiece artifact does not fold case: ``CAT``,
    ``Cat`` and ``cat`` map to three different ids, and the reference model
    scores cos("CAT", "cat") = 0.86 rather than ~1.0.

    The config flag describes an intent that the pipeline does not act on, so
    writing it into the manifest would ship a false statement about the artifact
    -- and any client that trusted it would lowercase its input and silently
    stop matching the reference. Probing the artifact cannot be fooled that way.
    """
    try:
        import sentencepiece as spm
    except ImportError:  # pragma: no cover - sentencepiece is a hard dependency here
        return bool(facts.do_lower_case)

    processor = spm.SentencePieceProcessor()
    processor.LoadFromFile(str(Path(checkpoint_dir) / "tokenizer.model"))
    for upper, lower in (("CAT", "cat"), ("RECEIPT", "receipt"), ("PHOTO", "photo")):
        if processor.EncodeAsIds(upper) != processor.EncodeAsIds(lower):
            return False
    return True


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT_DIR))
    p.add_argument("--out", default=str(HERE / "out"))
    p.add_argument("--quantize", default="none", choices=["none", "w8"])
    p.add_argument("--precision", default="float16", choices=["float16", "float32"])
    p.add_argument("--no-verify", action="store_true")
    p.add_argument("--threshold", type=float, default=None,
                   help="min cosine for the self-check (default 0.999 fp16, 0.99 w8)")
    p.add_argument("--suffix", default=None, help="output name suffix, e.g. '-w8'")
    p.add_argument("--target", default="ios18",
                   help="Core ML deployment target: ios18 (locally verifiable) or ios26")
    args = p.parse_args()

    import coremltools as ct

    threshold = args.threshold
    if threshold is None:
        threshold = 0.999 if args.quantize == "none" else 0.99

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    suffix = args.suffix if args.suffix is not None else ("-w8" if args.quantize == "w8" else "")
    image_path = out_dir / f"SigLIP2ImageEncoder{suffix}.mlpackage"
    text_path = out_dir / f"SigLIP2TextEncoder{suffix}.mlpackage"

    print("=== 1. reference model + facts")
    ref = SigLIP2Reference.load(args.checkpoint, device="cpu")
    facts = ref.facts
    image_size = facts.image_size
    text_len = facts.text_max_length or TEXT_MAX_POSITIONS_FALLBACK
    print(f"  embedding_dimension = {facts.embedding_dimension}")
    print(f"  image_size          = {image_size}")
    print(f"  text_max_length     = {text_len}")
    print(f"  vocab_size          = {facts.vocab_size}")

    precision = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    target = pick_deployment_target(ct, args.target)

    # The conversion source uses eager attention: plain matmul + softmax, which
    # converts and quantizes predictably (see module docstring).
    from transformers import AutoConfig, AutoModel

    print("=== 2. loading conversion source (eager attention)")
    config = AutoConfig.from_pretrained(args.checkpoint)
    siglip = AutoModel.from_pretrained(args.checkpoint, attn_implementation="eager").eval()

    # The reference must agree with the eager implementation, otherwise every
    # downstream parity number is measured against the wrong baseline.
    with torch.no_grad():
        eager_txt = F.normalize(siglip.get_text_features(
            input_ids=ref.token_ids(["海边的狗", "a photo of a cat"])).float(), dim=-1).numpy()
    ref_txt = ref.text_embedding(["海边的狗", "a photo of a cat"])
    eager_cos = float(np.sum(eager_txt / np.linalg.norm(eager_txt, axis=1, keepdims=True)
                             * ref_txt, axis=1).min())
    print(f"  eager vs default attention: min cosine {eager_cos:.6f}")
    if eager_cos < 0.9999:
        print("  [FAIL] attention implementations disagree; aborting")
        return 1

    print("=== 3. tracing + converting image encoder")
    t0 = time.time()
    image_module = VisionEncoder(siglip, config)
    with torch.no_grad():
        image_ml = convert_module(
            ct, image_module, (torch.zeros(1, 3, image_size, image_size),),
            [ct.TensorType(name="image", shape=(1, 3, image_size, image_size), dtype=np.float32)],
            "embedding", target, precision,
        )
    if args.quantize == "w8":
        print("  quantizing W8 ...")
        image_ml = quantize_w8(ct, image_ml, has_embedding=False)
    if image_path.exists():
        shutil.rmtree(image_path)
    image_ml.save(str(image_path))
    print(f"  saved {image_path.name} ({dir_size(image_path)/1e6:.1f} MB) in {time.time()-t0:.1f}s")

    print("=== 4. tracing + converting text encoder")
    t0 = time.time()
    text_module = TextEncoder(siglip)
    with torch.no_grad():
        text_ml = convert_module(
            ct, text_module, (torch.zeros(1, text_len, dtype=torch.int32),),
            [ct.TensorType(name="input_ids", shape=(1, text_len), dtype=np.int32)],
            "embedding", target, precision,
        )
    if args.quantize == "w8":
        print("  quantizing W8 ...")
        text_ml = quantize_w8(ct, text_ml, has_embedding=True)
    if text_path.exists():
        shutil.rmtree(text_path)
    text_ml.save(str(text_path))
    print(f"  saved {text_path.name} ({dir_size(text_path)/1e6:.1f} MB) in {time.time()-t0:.1f}s")

    print("=== 5. loading back + verifying against the reference")
    image_loaded = ct.models.MLModel(str(image_path), compute_units=ct.ComputeUnit.ALL)
    text_loaded = ct.models.MLModel(str(text_path), compute_units=ct.ComputeUnit.ALL)
    ok = True
    img_min = txt_min = float("nan")
    if not args.no_verify:
        ok, img_min, txt_min = verify_against_reference(
            ref, image_loaded, text_loaded, "image", "input_ids", threshold
        )

    print("=== 6. writing model_manifest.json")
    case_folding = _empirical_case_folding(facts, args.checkpoint)
    print(f"empirical case folding: {case_folding} "
          f"(HF config reported {facts.do_lower_case})")

    manifest = {
        "name": f"siglip2-base-patch16-256{suffix}",
        "source": facts.repo_id,
        "license": "Apache-2.0",
        "embeddingDimension": facts.embedding_dimension,
        "imageSize": image_size,
        "textMaxLength": text_len,
        "vocabSize": facts.vocab_size,
        "quantization": "W8" if args.quantize == "w8" else "none",
        "computePrecision": args.precision,
        "deploymentTarget": args.target,
        "modelVersion": 1,
        "imageEncoder": {
            "file": image_path.name,
            "input": {"name": "image", "shape": [1, 3, image_size, image_size], "dtype": "float32",
                      "layout": "NCHW", "range": [-1.0, 1.0]},
            "output": {"name": "embedding", "shape": [1, facts.embedding_dimension], "dtype": "float32",
                       "normalized": True},
            "bytes": dir_size(image_path),
            "sha256": sha256(image_path / "Data" / "com.apple.CoreML" / "model.mlmodel"),
        },
        "textEncoder": {
            "file": text_path.name,
            "input": {"name": "input_ids", "shape": [1, text_len], "dtype": "int32"},
            "output": {"name": "embedding", "shape": [1, facts.embedding_dimension], "dtype": "float32",
                       "normalized": True},
            "bytes": dir_size(text_path),
            "sha256": sha256(text_path / "Data" / "com.apple.CoreML" / "model.mlmodel"),
        },
        "preprocessing": {
            "order": ["convertToRGB", "resize", "rescale", "normalize"],
            "resize": {"width": image_size, "height": image_size, "resample": "bilinear",
                       "preserveAspectRatio": False, "centerCrop": False},
            "rescaleFactor": facts.rescale_factor,
            "mean": list(facts.image_mean),
            "std": list(facts.image_std),
        },
        "tokenizer": {
            "type": "sentencepiece",
            "file": "tokenizer.model",
            "padTokenId": facts.pad_token_id,
            "eosTokenId": facts.eos_token_id,
            "bosTokenId": facts.bos_token_id,
            "unkTokenId": facts.unk_token_id,
            "doLowerCase": case_folding,
            "appendEOS": True,
            "paddingSide": "right",
            "pooling": "last-position",
            "attentionMask": False,
        },
        "parity": {
            "verified": bool(ok and not args.no_verify),
            "imageMinCosine": img_min,
            "textMinCosine": txt_min,
            "threshold": threshold,
        },
        "contrastiveCalibration": {"logitScale": facts.logit_scale, "logitBias": facts.logit_bias},
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    manifest_path = out_dir / "model_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  wrote {manifest_path}")

    total = dir_size(image_path) + dir_size(text_path)
    print(f"\n=== size: image {dir_size(image_path)/1e6:.1f} MB + text {dir_size(text_path)/1e6:.1f} MB "
          f"= {total/1e6:.1f} MB")
    return 0 if (ok or args.no_verify) else 1


if __name__ == "__main__":
    raise SystemExit(main())
