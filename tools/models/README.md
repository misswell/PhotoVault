# `tools/models` — SigLIP2 reference, Core ML conversion and benchmarking

Everything here runs **on the Mac, outside the app**. Nothing in this directory
ships to users except the converted `.mlpackage` files and `tokenizer.model`
that are copied into the app bundle.

Spec sections implemented here: §3–§9 (model choice, conversion, quantization,
consistency testing, embedding standard, manifest, reproducibility).

```
tools/models/
├── requirements.txt        pinned dependency set (with the reasoning)
├── requirements-lock.txt   exact resolved versions (pip freeze)
├── siglip2_reference.py    the reference implementation — single source of truth
├── verify_siglip2.py       verification / parity harness (3 modes)
├── convert_siglip2.py      PyTorch -> Core ML conversion (+ self-check)
├── tune_quantization.py    sweep quantization configs against the quality gate
├── simulate_quantization.py  screen quantization in PyTorch before converting
├── benchmark_siglip2.py    throughput / latency / retrieval-quality gates
├── model_manifest.json     produced by convert_siglip2.py, consumed by the app
├── README.md               this file
├── cache/                  raw HF checkpoint — GITIGNORED, ~1.5 GB
├── out/                    converted .mlpackage — GITIGNORED, ~1.5 GB (all variants)
└── build/                  parity fixtures + benchmark logs — GITIGNORED
```

## Setup

```sh
cd tools/models
/opt/homebrew/bin/python3.12 -m venv .venv
./.venv/bin/python -m pip install -r requirements.txt
./.venv/bin/python -m pip freeze > requirements-lock.txt
```

Python 3.12 is required (coremltools 9.0 wheels). Do **not** use the system
`/usr/bin/python3` (3.9.6, ships transformers 4.30.2 which predates SigLIP2).

## Network

Two things about this machine's networking are worth writing down, because both
cost time to rediscover:

1. **`curl` cannot reach huggingface.co, but Python can.** macOS has a system
   HTTP/HTTPS proxy configured (`127.0.0.1:7890`, see `scutil --proxy`).
   Python's `requests`/`urllib` pick it up automatically via the System
   Configuration API; `curl` does not unless you export `HTTPS_PROXY`. So
   `curl https://huggingface.co/...` times out while the very same URL works
   from `./.venv/bin/python`.

2. **`hf-xet` must be disabled for the weights download.** With the xet
   transport active, fetching `model.safetensors` fails with
   `OSError: I/O error: Permission denied (os error 13)`. Plain HTTP works:

   ```sh
   HF_HUB_DISABLE_XET=1 ./.venv/bin/python -c "
   from huggingface_hub import snapshot_download
   snapshot_download('google/siglip2-base-patch16-256',
                     local_dir='cache/siglip2-base-patch16-256')"
   ```

   `requirements-lock.txt` pins `hf-xet`, so set the variable (or uninstall the
   package) whenever you re-download.

A mirror fallback exists (`HF_ENDPOINT=https://hf-mirror.com`) but it is not
needed on this machine, and its `/resolve/` HEAD requests 308-redirect back to
huggingface.co, which breaks `huggingface_hub`'s metadata calls. Prefer the
direct endpoint.

## Model

`google/siglip2-base-patch16-256` — **Apache-2.0**, which is why it is used
instead of Apple's MobileCLIP (whose official weights are research-only; see
spec §4). Recorded in `THIRD_PARTY_NOTICES.md` at the repo root.

Verified from the checkpoint (not assumed — see `verify_siglip2.py reference`):

| | value |
|---|---|
| checkpoint size | 1,500,985,224 B (1.501 GB), 408 F32 tensors |
| embedding dimension | **768** (both towers) |
| image size / patch | 256 / 16 → 256 tokens, 12 layers, hidden 768 |
| vision pooling | MAP (multihead attention pooling) head, `vision_model.head.probe` |
| text | 12 layers, hidden 768, **max 64 positions**, vocab **256000** (Gemma sentencepiece) |
| contrastive | `logit_scale` / `logit_bias` (SigLIP sigmoid loss) |

## Conventions the Swift side must reproduce

These were established by reading the checkpoint, the installed transformers
source, and the upstream maintainers — **not** by guessing. All five are
asserted by `verify_siglip2.py reference`, and each one is a place where a
plausible-looking implementation is silently wrong.

1. **Text padding length must be passed explicitly.** The tokenizer's
   `model_max_length` is a `1e30` sentinel, so the model card's
   `processor(text=..., padding="max_length")` snippet **silently performs no
   padding** (transformers logs a warning and returns unpadded sequences).
   Always pass `max_length = text_config.max_position_embeddings` (= 64).

2. **Pooling takes the last position, pad or not.** Tokenization appends
   `<eos>` (id 1) and then right-pads with `<pad>` (id 0), so position 63 is a
   *pad* for any short text. That is intended: SigLIP/SigLIP2 were trained
   **without** an attention mask, and the maintainer who converted the model
   confirmed the last position is pooled "regardless whether it's a pad or
   eos" ([transformers#39269](https://github.com/huggingface/transformers/issues/39269)).
   Consequence: the text encoder needs **no attention mask** and a fully static
   `[1, 64]` input — ideal for Core ML.

3. **`do_convert_rgb` is `null` in the checkpoint.** The image processor treats
   that as falsy, so an RGBA input raises `Unable to infer channel dimension
   format`. PhotoVault's screenshots *are* RGBA, so we always convert to RGB
   ourselves and pass `do_convert_rgb=True` explicitly (a byte-identical no-op
   for already-RGB input, which the harness asserts).

4. **Resize is a direct 256×256 squash** with `resample=2` (bilinear) — no
   centre crop, aspect ratio not preserved. Pillow's bilinear and
   CoreGraphics' resampling will never be bit-identical, which is exactly why
   parity is measured at two levels (see below).

5. **`AutoModel` resolves to `SiglipModel`, not `Siglip2Model`**, because the
   checkpoint's `config.json` declares `model_type: "siglip"`. That is correct:
   the v1 vision transformer instantiates the MAP head whenever the config
   lacks `vision_use_head`, and the checkpoint ships `vision_model.head.*`
   weights. The harness proves both classes produce identical embeddings, and
   `siglip2_reference.py` additionally fails hard if **any** tensor in the
   checkpoint file goes unused — a dropped MAP head still yields finite,
   normalized, plausible-looking embeddings.

## Measured results (2026-09-13, Apple M1)

All numbers from this machine, against the 57-image / 50-query parity fixture
set. Parity is cosine similarity between the Core ML embedding and the FP32
PyTorch reference embedding.

| model | image | text | total | image parity (real) | text parity | text nDCG@20 loss |
|---|---|---|---|---|---|---|
| FP32 (reference) | 369.5 MB | 1129.3 MB | 1498.8 MB | 1.000000 | 1.000000 | 0% |
| **FP16** | 184.8 MB | 564.8 MB | 749.6 MB | 0.999817 | 0.999999 | 0% |
| **W8** | 93.0 MB | 283.3 MB | **376.3 MB** | **0.999072** | **0.999050** | **0.06%** |

FP32 reproduces the reference **exactly** (cosine 1.000000 for all 57 images and
50 queries), which is what makes the FP16 and W8 residuals interpretable as
precision loss rather than conversion error.

Encoder cost on this Mac (an M1 — treat as a floor, not a device claim; the app
must still be measured on an iPhone 15 Pro):

| | P50 | P95 | throughput |
|---|---|---|---|
| image encoder | 9.4 ms | 9.7 ms | 107 images/s |
| text encoder | 10.7 ms | 11.5 ms | — |

Exact retrieval over a 100 000 × 768 FP16 matrix (153.6 MB) is P50 18.3 ms /
P95 99.4 ms in NumPy/BLAS — i.e. the spec's 500 ms / 1000 ms budget is met with
roughly 25× headroom before the Metal kernel is even written.

## The quantization trap (read this before changing `quantize_w8`)

The first W8 attempt used the obvious documented recipe — `linear_symmetric`,
int8, `per_channel`, applied globally — and produced a model that looked fine by
size (376 MB) but was **broken as a search engine**:

* image embedding collapsed to **0.932** cosine on real photos (nDCG@20 0.9185,
  an 8% retrieval loss against a 1.5% budget)
* text embedding fell to 0.9836

The weights were quantized *correctly* — the layer-0 `q_proj` dequantized from
the mlpackage matches a hand-rolled per-output-channel int8 quantizer to
cosine 0.999993. The damage came from a tensor nobody would suspect:

> In the traced vision graph, the **position embedding** is folded into a
> constant `[1, 256, 768]` — its `position_ids` buffer is constant, so the
> gather disappears — and that constant then feeds an `add`.
> `linear_quantize_weights` quantizes it anyway.

Quantizing that one tensor alone drops the image embedding to 0.966 cosine on
real photos (mean 0.957) in simulation: far more sensitive than any encoder
layer. `quantize_w8` therefore selects consts by **consumer op type**, and only
quantizes a const when every op reading it is a genuine weight-bearing op
(`linear`, `conv`, `gather`). Anything feeding `add` / `mul` / `reshape` /
`transpose` stays in FP16. The two position embeddings are among the excluded
tensors, and the run logs every skip so the decision is auditable.

Two more findings worth keeping:

* **Do not run a second quantization pass.** The first attempt also applied
  `palettize_weights` over `global_config`, which re-quantized the already-int8
  linears and cost ~1.5 points of text cosine for zero size benefit.
* **The vision tower is not fragile in general.** A random 0.1% relative
  perturbation of every vision weight costs only 0.00004 cosine; 1% costs
  0.011. The failure above was one specific tensor, not a property of the
  architecture — so `simulate_quantization.py` is safe to use for screening, as
  long as it models *every* tensor Core ML will touch. Its first version only
  quantized `nn.Linear`/`nn.Conv2d` weights and therefore predicted 0.9995 for a
  configuration that actually measured 0.93.

`simulate_quantization.py` answers quantization-quality questions in seconds in
PyTorch; use it to rank candidates, then confirm the winner with
`verify_siglip2.py coreml`, which is the authority on the converted artifact.

## Workflow

```sh
# 1. FP16 Core ML baseline (spec order: FP32 reference -> FP16 -> W8)
./.venv/bin/python verify_siglip2.py reference
./.venv/bin/python convert_siglip2.py                      # writes out/*.mlpackage + model_manifest.json

# 2. W8 quantization, gated on ranking quality, not vibes
#    (--suffix needs `=` : argparse reads `-w8` as an option, not a value)
./.venv/bin/python convert_siglip2.py --quantize w8 --suffix=-w8
./.venv/bin/python benchmark_siglip2.py --compare \
    out/SigLIP2TextEncoder.mlpackage:fp16 out/SigLIP2TextEncoder-w8.mlpackage:w8
# gate: nDCG@20 relative loss <= 1.5%, otherwise the W8 model is rejected

# 3. Fixtures for the Swift/Core ML parity test
./.venv/bin/python verify_siglip2.py walk --out build/parity
./.venv/bin/python verify_siglip2.py coreml --fixtures build/parity \
    --image-model out/SigLIP2ImageEncoder.mlpackage \
    --text-model out/SigLIP2TextEncoder.mlpackage --threshold 0.999

# 4. Tokenizer parity once the Swift port exists
./.venv/bin/python verify_siglip2.py tokenizer --swift build/swift-tokens.json
```

### Two levels of parity

* **L1 — model parity (threshold cos ≥ 0.999).** Swift feeds the *identical*
  float input from `image_input.bin` / `text_input.bin` into the Core ML
  MultiArray inputs. Any residual is the converted model, never the
  preprocessing. This is the check that must never fail.
* **L2 — pipeline parity.** Swift loads the original file and runs its own
  RGB + resize + normalize. A slightly lower cosine is expected and *acceptable
  only* because Pillow and CoreGraphics resample differently; quantify it and
  record the number rather than loosening L1.

Never "fix" a parity failure by adjusting search weights (spec §7).

## Output contract

`convert_siglip2.py` writes `out/model_manifest.json`. The app reads it — it
must never hardcode dimensions:

```json
{
  "embeddingDimension": 768,
  "imageSize": 256,
  "textMaxLength": 64,
  "vocabSize": 256000,
  "quantization": "none",
  "modelVersion": 1,
  "imageEncoder": { "file": "...", "sha256": "...",
                    "input": {"name": "image", "shape": [1,3,256,256], "dtype": "float32"} },
  "textEncoder":  { "file": "...", "sha256": "...",
                    "input": {"name": "input_ids", "shape": [1,64], "dtype": "int32"} },
  "parity": { "verified": true, "imageMinCosine": 0.9999, "textMinCosine": 0.9999 }
}
```

## Size expectations

FP32 text tower is 1.13 GB, of which the 256000×768 token embedding table is
786 MB. Approximate bundle cost of the two encoders:

| variant | image | text | total |
|---|---|---|---|
| FP16 | ≈186 MB | ≈565 MB | ≈750 MB |
| **W8** | ≈95 MB | ≈285 MB | **≈380 MB** |

This is the project's largest open risk; the decision on how to ship it
(bundle / embedding-table pruning / Apple-Hosted Background Assets) is tracked
in `docs/AI_SEARCH_BASELINE.md` §8 R1 and §11 D1. Measure the real sizes here
and record them — do not estimate.

## Licensing

* Model weights: `google/siglip2-base-patch16-256`, **Apache-2.0**.
* `tokenizer.model` is distributed with the same checkpoint.
* Both must be listed in `THIRD_PARTY_NOTICES.md` before release (spec §4/§82).
