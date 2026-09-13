#!/usr/bin/env python3
"""SigLIP2 reference implementation — the single source of truth for PhotoVault.

Everything the Swift / Core ML side must reproduce is defined here exactly once:

  * image preprocessing (resize / rescale / normalize / channel order)
  * text tokenization (EOS handling, right padding, padding length)
  * pooling (which position is pooled)
  * L2 normalization

Nothing about the model may be hardcoded in business code. All constants are
read back from the checkpoint and exposed as :class:`ModelFacts`, so a model
swap is a data change, not a code change.

--------------------------------------------------------------------------
Conventions verified against the checkpoint, transformers 4.53.3 and the
upstream maintainers (do not "clean these up" without re-running
``verify_siglip2.py``):

1. ``config.json`` only carries ``vocab_size`` and ``image_size`` (276 bytes).
   Layer counts / hidden sizes / ``max_position_embeddings`` come from the
   ``SiglipConfig`` class defaults, so they MUST be asserted against the
   actual weight shapes rather than trusted.

2. ``model_type`` is ``"siglip"``, so ``AutoModel`` resolves to ``SiglipModel``
   (the v1 class), NOT ``Siglip2Model``. That is correct: the v1 vision
   transformer instantiates the Multihead-Attention-Pooling head whenever the
   config has no ``vision_use_head`` key, and the checkpoint does ship
   ``vision_model.head.*`` (``probe`` etc.). ``verify_siglip2.py`` proves both
   classes produce identical embeddings.

3. Text: the tokenizer appends ``<eos>`` (id 1) and then right-pads with
   ``<pad>`` (id 0). ``padding="max_length"`` alone is a TRAP — this
   checkpoint's ``model_max_length`` is the 1e30 sentinel, so transformers
   silently degrades to "no padding" (with a warning). ``max_length`` MUST be
   passed explicitly, and it comes from ``text_config.max_position_embeddings``.

4. Pooling is ``last_hidden_state[:, -1, :]`` — the LAST position, which after
   right-padding is a ``<pad>`` position, not EOS. This is intended, not a bug:
   SigLIP/SigLIP2 were trained WITHOUT an attention mask for padding, and the
   maintainer who converted the model confirmed the last position is pooled
   "regardless whether it's a pad or eos"
   (https://github.com/huggingface/transformers/issues/39269).
   Consequence: text input is a static ``[1, 64]`` int32 tensor with NO
   attention mask — which is ideal for Core ML.

5. ``preprocessor_config.json`` has ``"do_convert_rgb": null``. The class
   treats that as falsy, so an RGBA/gray image is NOT converted and
   ``SiglipImageProcessor`` raises "Unable to infer channel dimension format".
   PhotoVault's screenshots are RGBA, so we always convert to RGB ourselves and
   pass ``do_convert_rgb=True`` explicitly. For an already-RGB image the two
   paths are byte-identical (asserted in ``verify_siglip2.py``).

6. Resize is a direct 256x256 resize with ``resample=2`` (BILINEAR) — aspect
   ratio is NOT preserved and there is no centre crop.

7. Embeddings are L2-normalized, so ``cosine_similarity == dot``.

Usage:
    from siglip2_reference import SigLIP2Reference
    ref = SigLIP2Reference.load()                  # default cache dir
    img = ref.image_embedding(["a.png", "b.jpg"])  # [2, 768] float32, unit norm
    txt = ref.text_embedding(["海边的狗"])          # [1, 768] float32, unit norm
    scores = img @ txt.T                           # cosine similarities
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np
import torch
from PIL import Image

# Repo layout: tools/models/siglip2_reference.py
HERE = Path(__file__).resolve().parent
DEFAULT_CHECKPOINT_DIR = HERE / "cache" / "siglip2-base-patch16-256"
REPO_ID = "google/siglip2-base-patch16-256"


# --------------------------------------------------------------------------
# Facts read back from the checkpoint
# --------------------------------------------------------------------------
@dataclass
class ModelFacts:
    """Everything about the model that the Swift side needs.

    Written into ``model_manifest.json`` by ``convert_siglip2.py`` so the app
    never hardcodes a dimension.
    """

    repo_id: str
    resolved_model_class: str
    embedding_dimension: int
    projection_size: int
    image_size: int
    image_mean: tuple
    image_std: tuple
    resample: int
    rescale_factor: float
    do_convert_rgb_config: object
    text_max_length: int
    pad_token_id: int
    eos_token_id: int
    bos_token_id: int
    unk_token_id: int
    tokenizer_model: str
    do_lower_case: bool
    # architecture, asserted against the safetensors header
    vision_layers: int
    vision_hidden_size: int
    vision_patch_size: int
    vision_position_embeddings: int
    text_layers: int
    text_hidden_size: int
    text_position_embeddings: int
    vocab_size: int
    # SigLIP contrastive calibration: logit = dot * scale + bias
    logit_scale: float
    logit_bias: float
    dtype: str = "float32"

    def as_manifest(self) -> dict:
        d = asdict(self)
        d["image_mean"] = list(self.image_mean)
        d["image_std"] = list(self.image_std)
        return d


# --------------------------------------------------------------------------
# Image loading
# --------------------------------------------------------------------------
def load_image_rgb(path_or_image) -> Image.Image:
    """Load an image as 8-bit RGB, matching what ``convert_to_rgb`` would do.

    This is deliberately done on our side because the checkpoint's
    ``do_convert_rgb`` is ``null`` (see module docstring, note 5).
    """
    if isinstance(path_or_image, Image.Image):
        img = path_or_image
    else:
        img = Image.open(path_or_image)
    if img.mode != "RGB":
        img = img.convert("RGB")
    return img


# --------------------------------------------------------------------------
# Reference model
# --------------------------------------------------------------------------
class SigLIP2Reference:
    """Loads the checkpoint and produces L2-normalized image/text embeddings."""

    def __init__(self, model, processor, facts: ModelFacts, device: str):
        self.model = model
        self.processor = processor
        self.facts = facts
        self.device = device

    # -- construction ------------------------------------------------------
    @classmethod
    def load(
        cls,
        checkpoint_dir: os.PathLike | str = DEFAULT_CHECKPOINT_DIR,
        device: str = "cpu",
        dtype: torch.dtype = torch.float32,
    ) -> "SigLIP2Reference":
        # Imported lazily so `--help` and pure-arithmetic tooling stay fast.
        from transformers import AutoConfig, AutoModel, AutoProcessor

        checkpoint_dir = str(checkpoint_dir)
        config = AutoConfig.from_pretrained(checkpoint_dir)
        # transformers 4.53 spells this `torch_dtype` (the `dtype` alias only
        # exists in later releases), and passing the alias straight through
        # fails inside SiglipModel.__init__.
        load_kwargs = {} if dtype is torch.float32 else {"torch_dtype": dtype}
        model = AutoModel.from_pretrained(checkpoint_dir, **load_kwargs)
        model.eval().to(device)

        # use_fast=False pins the SAVED slow processor: transformers warns that
        # the fast image processor produces "minor differences in outputs".
        processor = AutoProcessor.from_pretrained(checkpoint_dir, use_fast=False)

        facts = cls._read_facts(checkpoint_dir, config, model, processor)
        return cls(model, processor, facts, device)

    @staticmethod
    def _read_facts(checkpoint_dir, config, model, processor) -> ModelFacts:
        ip = processor.image_processor
        tok = processor.tokenizer
        vc, tc = config.vision_config, config.text_config
        sd = model.state_dict()

        def shape(name):
            if name not in sd:
                raise AssertionError(f"expected tensor {name!r} missing from the checkpoint")
            return tuple(sd[name].shape)

        vision_layers = len({k.split(".")[3] for k in sd if k.startswith("vision_model.encoder.layers.")})
        text_layers = len({k.split(".")[3] for k in sd if k.startswith("text_model.encoder.layers.")})

        # Every tensor in the checkpoint file must be consumed by the model.
        # A silently ignored tensor (e.g. the MAP head) produces plausible but
        # wrong embeddings, which is the single most dangerous failure mode of
        # this conversion, so it is a hard error rather than a warning.
        consumed = _assert_all_weights_consumed(checkpoint_dir, model)
        assert consumed > 0

        # The MAP head must exist, otherwise pooling silently falls back to None
        # and every image embedding is garbage.
        if "vision_model.head.probe" not in sd:
            raise AssertionError(
                "vision_model.head.probe missing: the Multihead-Attention-Pooling head "
                "was not instantiated, so image embeddings would be wrong"
            )

        # Assert class defaults against the real weights (see docstring note 1).
        checks = {
            "vision_layers": (vision_layers, vc.num_hidden_layers),
            "text_layers": (text_layers, tc.num_hidden_layers),
            "vision_hidden": (shape("vision_model.embeddings.patch_embedding.weight")[0], vc.hidden_size),
            "text_hidden": (shape("text_model.final_layer_norm.weight")[0], tc.hidden_size),
            "vision_positions": (shape("vision_model.embeddings.position_embedding.weight")[0], vc.image_size // vc.patch_size * (vc.image_size // vc.patch_size)),
            "text_positions": (shape("text_model.embeddings.position_embedding.weight")[0], tc.max_position_embeddings),
            "vocab": (shape("text_model.embeddings.token_embedding.weight")[0], tc.vocab_size),
            "projection": (shape("text_model.head.weight")[0], tc.projection_size),
        }
        for label, (actual, declared) in checks.items():
            if actual != declared:
                raise AssertionError(f"{label}: checkpoint has {actual}, config declares {declared}")

        return ModelFacts(
            repo_id=REPO_ID,
            resolved_model_class=type(model).__name__,
            embedding_dimension=shape("text_model.head.weight")[0],
            projection_size=tc.projection_size,
            image_size=vc.image_size,
            image_mean=tuple(float(x) for x in ip.image_mean),
            image_std=tuple(float(x) for x in ip.image_std),
            resample=int(ip.resample),
            rescale_factor=float(ip.rescale_factor),
            do_convert_rgb_config=ip.do_convert_rgb,
            text_max_length=int(tc.max_position_embeddings),
            pad_token_id=int(tok.pad_token_id),
            eos_token_id=int(tok.eos_token_id),
            bos_token_id=int(tok.bos_token_id),
            unk_token_id=int(tok.unk_token_id),
            tokenizer_model="tokenizer.model (sentencepiece)",
            do_lower_case=bool(
                getattr(tok, "do_lower_case", None)
                if getattr(tok, "do_lower_case", None) is not None
                else getattr(tok, "init_kwargs", {}).get("do_lower_case", False)
            ),
            vision_layers=vision_layers,
            vision_hidden_size=vc.hidden_size,
            vision_patch_size=vc.patch_size,
            vision_position_embeddings=shape("vision_model.embeddings.position_embedding.weight")[0],
            text_layers=text_layers,
            text_hidden_size=tc.hidden_size,
            text_position_embeddings=shape("text_model.embeddings.position_embedding.weight")[0],
            vocab_size=tc.vocab_size,
            logit_scale=float(sd["logit_scale"].reshape(-1)[0]),
            logit_bias=float(sd["logit_bias"].reshape(-1)[0]),
        )

    # -- preprocessing -----------------------------------------------------
    def image_tensor(self, images: Sequence) -> torch.Tensor:
        """Return the exact NCHW float32 input the vision tower expects.

        The tensor returned here can be handed verbatim to the Core ML image
        encoder, which is what makes the parity test meaningful: it isolates
        the model from any resize differences.

        ``SiglipProcessor.__call__`` does not forward ``do_convert_rgb`` to the
        image processor, so we call the image processor directly. Passing
        ``do_convert_rgb=True`` is a no-op for the already-RGB images produced
        by :func:`load_image_rgb`, and it pins the behaviour that the
        checkpoint leaves as ``null``.
        """
        rgb = [load_image_rgb(i) for i in images]
        out = self.processor.image_processor(
            images=rgb, do_convert_rgb=True, return_tensors="pt"
        )
        return out["pixel_values"].to(torch.float32)

    def token_ids(self, texts: Sequence[str]) -> torch.Tensor:
        """Return the exact [N, max_length] int32 token ids the text tower expects.

        * ``<eos>`` is appended by the tokenizer, then the sequence is
          right-padded with ``<pad>``.
        * ``max_length`` is passed explicitly: the checkpoint's
          ``model_max_length`` is a 1e30 sentinel and ``padding="max_length"``
          alone silently disables padding.
        * No attention mask: SigLIP/SigLIP2 were trained without one and the
          model pools the last position regardless.
        """
        out = self.processor.tokenizer(
            text=list(texts),
            padding="max_length",
            max_length=self.facts.text_max_length,
            truncation=True,
            return_tensors="pt",
        )
        return out["input_ids"].to(torch.int32)

    # -- embeddings --------------------------------------------------------
    @torch.no_grad()
    def image_embedding_from_tensor(self, pixel_values: torch.Tensor) -> np.ndarray:
        pixel_values = pixel_values.to(self.device)
        feats = self.model.get_image_features(pixel_values=pixel_values)
        return _l2_normalize(feats.float().cpu().numpy())

    @torch.no_grad()
    def text_embedding_from_ids(self, input_ids: torch.Tensor) -> np.ndarray:
        input_ids = input_ids.to(self.device)
        feats = self.model.get_text_features(input_ids=input_ids)
        return _l2_normalize(feats.float().cpu().numpy())

    def image_embedding(self, images: Sequence) -> np.ndarray:
        """Normalized image embeddings, shape [N, D], float32."""
        return self.image_embedding_from_tensor(self.image_tensor(images))

    def text_embedding(self, texts: Sequence[str]) -> np.ndarray:
        """Normalized text embeddings, shape [N, D], float32."""
        return self.text_embedding_from_ids(self.token_ids(texts))

    # -- retrieval ---------------------------------------------------------
    def similarity(self, images: Sequence, texts: Sequence[str]) -> np.ndarray:
        """Cosine similarity matrix [n_images, n_texts] (embeddings are unit norm)."""
        return self.image_embedding(images) @ self.text_embedding(texts).T

    def search(self, query: str, image_paths: Sequence, top_k: int = 10):
        """Trivial cosine ranking — the Phase 1 baseline the Swift side must match."""
        sims = self.similarity(image_paths, [query]).reshape(-1)
        order = np.argsort(-sims)[:top_k]
        return [(image_paths[i], float(sims[i])) for i in order]

    # -- parity harness support -------------------------------------------
    def dump_parity(
        self,
        out_dir: os.PathLike | str,
        images: Sequence,
        texts: Sequence[str],
        image_kinds: Sequence[str] | None = None,
    ) -> Path:
        """Write everything the Swift parity test needs to a directory.

        Two levels of parity are supported:

        L1 model parity — feed the *identical* float input
            ``image_input.bin`` float32 little-endian, N x 3 x 256 x 256 (NCHW,
            already rescaled and normalized)
            ``text_input.bin``  int32 little-endian, N x max_text_length
            Swift can feed these straight into the Core ML MultiArray inputs,
            which isolates the converted model from any resize difference.

        L2 pipeline parity — Swift loads ``manifest.json["image_paths"]``
            itself, runs its own RGB + resize + normalize, and must land within
            the documented threshold of ``image_embeddings`` (the residual is
            Pillow-bilinear vs CoreGraphics resampling, nothing else).

        Embeddings are L2-normalized float32 row-major.
        """
        out_dir = Path(out_dir).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)

        pixel = self.image_tensor(images).contiguous()
        ids = self.token_ids(texts).contiguous()
        img_emb = self.image_embedding_from_tensor(pixel)
        txt_emb = self.text_embedding_from_ids(ids)

        (out_dir / "image_input.bin").write_bytes(pixel.numpy().astype("<f4").tobytes())
        (out_dir / "text_input.bin").write_bytes(ids.numpy().astype("<i4").tobytes())

        # Store image paths relative to the fixture root so the directory can be
        # moved into the app bundle or a test target without editing.
        rel_paths = []
        for p in images:
            p = Path(p).resolve()
            try:
                rel_paths.append(str(p.relative_to(out_dir)))
            except ValueError:
                rel_paths.append(str(p))

        manifest = {
            "facts": self.facts.as_manifest(),
            "image_paths": rel_paths,
            # "real" vs "synthetic" so consumers can apply tiered gates: FP16
            # rounding shows up far more on adversarial synthetic content
            # (high-frequency noise, hard edges) than on photographs.
            "image_kinds": list(image_kinds) if image_kinds is not None
            else ["real"] * len(rel_paths),
            "text_queries": [str(t) for t in texts],
            "image_input_shape": list(pixel.shape),
            "text_input_shape": list(ids.shape),
            "image_embeddings": img_emb.tolist(),
            "text_embeddings": txt_emb.tolist(),
        }
        (out_dir / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False), encoding="utf-8"
        )
        return out_dir


def _assert_all_weights_consumed(checkpoint_dir, model) -> int:
    """Fail loudly if any tensor in the checkpoint file was not loaded.

    ``from_pretrained`` reports unused weights as a warning that is easy to
    miss in a build log; a dropped MAP head would still produce finite,
    normalized, plausible-looking embeddings.
    """
    from safetensors import safe_open

    weights_path = Path(checkpoint_dir) / "model.safetensors"
    if not weights_path.exists():
        raise FileNotFoundError(f"missing weights: {weights_path}")

    with safe_open(str(weights_path), framework="pt") as handle:
        file_keys = set(handle.keys())

    model_keys = set(model.state_dict().keys())
    unused = sorted(file_keys - model_keys)          # in file, ignored by model
    unfilled = sorted(model_keys - file_keys)        # in model, no weights
    if unused or unfilled:
        raise AssertionError(
            "weight/key mismatch between checkpoint file and model — "
            f"ignored={unused[:8]}{'…' if len(unused) > 8 else ''} "
            f"unfilled={unfilled[:8]}{'…' if len(unfilled) > 8 else ''} "
            f"(unused {len(unused)}, unfilled {len(unfilled)})"
        )
    return len(file_keys)


def _l2_normalize(x: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(x, axis=-1, keepdims=True)
    return x / np.maximum(norm, 1e-12)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main() -> int:
    import argparse

    p = argparse.ArgumentParser(description="SigLIP2 reference: embeddings and semantic search")
    p.add_argument("--checkpoint", default=str(DEFAULT_CHECKPOINT_DIR))
    p.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    p.add_argument("--images", nargs="*", default=[], help="image paths to search over")
    p.add_argument("--queries", nargs="*", default=[], help="text queries")
    p.add_argument("--top-k", type=int, default=5)
    p.add_argument("--dump-facts", action="store_true", help="print the model facts as JSON")
    p.add_argument("--dump-parity", metavar="DIR", help="dump parity fixtures for the Swift/Core ML test")
    args = p.parse_args()

    if not args.images and not args.queries and not args.dump_facts and not args.dump_parity:
        p.print_help()
        return 0

    ref = SigLIP2Reference.load(args.checkpoint, device=args.device)

    if args.dump_facts:
        print(json.dumps(ref.facts.as_manifest(), indent=2, ensure_ascii=False))

    if args.images and args.queries:
        for q in args.queries:
            print(f"\n=== {q}")
            for path, score in ref.search(q, args.images, args.top_k):
                print(f"  {score:.4f}  {path}")

    if args.dump_parity:
        if not args.images or not args.queries:
            p.error("--dump-parity requires --images and --queries")
        out = ref.dump_parity(args.dump_parity, args.images, args.queries)
        print(f"\nwrote parity fixtures to {out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
