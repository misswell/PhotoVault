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
├── siglip2_tokenizer.py    tokenizer executable spec + binary artifact generator
├── build_tokenizer_corpus.py  adversarial corpus for the tokenizer parity test
├── tokenizer_test/         Swift harness, compiled against the app's tokenizer
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

## The embedding matrix file (Phase 3)

`PhotoVault/Search/EmbeddingStoreFile.swift` owns `embeddings-v1.bin`: a
4096-byte header page followed by fixed-size **Float16** vectors, memory-mapped
for search.

    python verify_siglip2.py embedding      # 3/3 checks

| check | result |
|---|---|
| unit tests (round trip, growth, swap-remove, corruption) | **34/34** |
| 100k x 768 exact scan, Accelerate fallback | **P50 20.3 ms** |
| NumPy independently recomputes the top-100 from the same file | **exact match, 1.19e-7 score delta** |

### Two design decisions worth knowing

**The matrix is kept dense.** The obvious layout is a slot allocator with a free
list, so deletions leave reusable holes. That is wrong here: search is the hot
path and wants to stream a contiguous block of vectors, while holes force either
a gather (random access, defeats prefetching, awkward in a Metal kernel) or
validity checks inside the inner loop. So deletion is **swap-remove** — the last
row moves into the hole and the count drops. The cost is one row copy per
deletion plus a SQLite row update for the asset that moved.

The consequence to remember: **slot indices are not stable**. SQLite is the
source of truth for `asset_id -> slot`, and `swapRemove` must be applied in the
same transaction as the row update that follows it.

**A scalar loop was measurably the wrong choice.** The first Accelerate fallback
used a per-component loop, which is the "no scalar double loop" case the plan
calls out. Under one identical warm-up protocol, 100k x 768:

| implementation | warm P50 |
|---|---|
| scalar per-component loop | 68.0 ms |
| 512-row blocks: `vDSP.convertElements` + `cblas_sgemv` | 11.2 ms |
| Metal kernel | 7.5 ms |

Converting the whole matrix to Float32 up front would be faster still but doubles
resident memory to 307 MB, defeating the point of storing Float16.

> An earlier version of this note quoted 20.3 ms for the Accelerate path and
> described it as 3x faster than the scalar loop. That measurement mixed cold and
> warm scans: a first pass over a freshly built 192 MB file page-faults and costs
> **31.1 ms** against **9.5 ms** steady state. The benchmark now reports both, and
> the table above compares all three under the same warm protocol.

**On first-search latency.** The cold 31.1 ms is real and is what the *first*
search after launch pays. It is a page-fault cost, not a compute cost, and it
disappears once the pages are resident.

Note also: `vDSP_vflt16` is the *integer* 16-bit converter and would silently
reinterpret IEEE halves as Int16. The typed `vDSP.convertElements` API is the
Float16-aware one.

### The invariant the fast path depends on

`scores` normalizes only the **query**, which is what makes it one multiply-add
per component. That is correct because the Core ML graph bakes L2 normalization
into the embedding. If a row ever arrived un-normalized the result would not be
an error — it would be a *ranking*, silently wrong in proportion to that row's
magnitude. `validateNormalization()` therefore exists so the store can turn that
into a loud failure after a write batch, and the NumPy check re-verifies it
independently (measured deviation `3.9e-5`, the Float16 rounding floor).

A damaged header is a cache miss, not data loss: everything here is derived from
PhotoKit and the model. The checksum exists to *detect* damage cheaply and force
a rebuild, mirroring how `PhotoIndexStore` treats its own database — not to
enable recovery nobody needs.

## The Swift image encoder (Phase 3)

`PhotoVault/Search/SigLIP2VisionEncoder.swift`. `python verify_siglip2.py vision`
— **17/17**. Until this existed the pipeline had no way to *populate* the index:
the tokenizer, text tower, matrix, search and analyzer were each verified, but
every embedding had to come from Python.

### Preprocessing is reproduced, not approximated

The manifest order is convertToRGB → resize → rescale → normalize, and the resize
**squashes to a square**: an 811x2168 screenshot is distorted to 256x256 with the
aspect ratio discarded. That is what the reference did, so that is what this does.
"Improving" it with aspect preservation or a centre crop would silently embed
every photo differently from the model that was verified.

`PILResampler` reproduces PIL's algorithm including two details an independent
implementation usually gets wrong:

1. **The triangle filter widens on a large downscale** (`support * max(1, src/dst)`),
   making it area-averaging. A fixed-support bilinear sampling the nearest four
   pixels aliases badly on a 2168 → 256 reduction, embedding a moire pattern the
   reference never saw.
2. **PIL clamps to 8 bits after each pass** and quantizes coefficients to 22-bit
   fixed point. Floating point throughout is *more accurate* and produces
   *different* pixels.

### Decoding and resampling are verified separately

The first run failed on `.jpg` fixtures while PNGs matched to the last bit — the
signature of a decoder difference, not a resampling bug. Apple's ImageIO and
libjpeg implement the IDCT and chroma upsampling differently, so the same JPEG
yields different pixels before any resizing.

Those two failures need different responses, so they are now measured separately.
`dump_resample_fixtures.py` dumps PIL's exact RGB bytes; feeding those to the
Swift resampler removes decoding from the comparison entirely:

| comparison | result |
|---|---|
| resampler, **identical pixels** (57 images) | **max difference 0.000000 — bit-exact** |
| full image path, PNG (lossless) | within one 8-bit level |
| full image path, JPEG | tensor cos 0.9986–0.99999 |

The dumper self-checks against `image_input.bin` and reports **0.000000**, so its
fixtures are trustworthy rather than merely self-consistent.

**The honest limitation:** the app decodes JPEGs with the platform decoder, so it
cannot reproduce libjpeg's pixels, and an extreme aspect ratio squashed to a
square amplifies the difference. Worst measured embedding cosine is **0.994844**
(`synthetic-001.jpg`, 124x2057). The conversion's own W8 image parity is 0.99977
with Python preprocessing, so the ~0.005 gap is entirely the decoder. The floor is
0.99 with the measured values printed above it, so a regression is visible before
it reaches the floor.

### Measured

Warm encode **P50 52.7 ms** (CPU+GPU, macOS); first prediction 6.4 s including
Core ML load and shape specialization. Output norm 0.9997647, confirming the
conversion bakes normalization in — the invariant the search's single
multiply-add shortcut depends on.

`build/parity/resample/` holds ~700 MB of regenerable fixtures. It is gitignored
and rebuilt on demand; deleting it costs one regeneration.

## The search engine (Phases 5-8 assembled)

`PhotoVault/Search/PhotoSearchEngine.swift`. `python verify_siglip2.py search`
(58/58 checks) —
**46/46**, all eight components driven end to end: query string → analyzer →
gazetteer → SQLite → mmap matrix → scores → ranked asset IDs.

### The ordering rule the whole design rests on

> the model decides what a photo *looks like*;
> the engine decides which photos are even candidates, and how the model's
> opinions combine.

A query like `2023年在北京拍的发票` never reaches the vector scan for the date or
the place. Those are answered by SQL, and the text tower is asked only about the
part it is good at. **Scoring 100k rows to answer a question about a calendar is
the failure mode this exists to prevent.**

### Filter-first, not post-filter

Candidates are selected in SQLite *before* any vector is computed, via the new
`EmbeddingMatrixReader.scores(query:slots:)`. The alternative — rank everything,
then drop what doesn't match — returns fewer than K results whenever the filter
is selective, **and looks like the filter working**. Restricting the scan is both
correct and, for a selective filter, far less work.

### AND is a conjunction, not an average

`QueryPlan.combine == .all` takes the **minimum** across clauses, not the mean.
Averaging lets one strong clause carry a photo that lacks the other entirely, so
"猫和沙滩" would happily return a photo of a cat indoors. `min` is still a
heuristic for AND — a true AND needs a per-concept threshold — but it errs toward
demanding every concept be present, which is what the user asked for.

Negation **rejects** rather than penalises: subtracting a score would let a
strong enough positive clause overwhelm "not a dog", which is the one outcome the
user explicitly ruled out.

### An unresolved place is handed to the model, not dropped

The analyzer extracts any place-like mention, including ones no gazetteer knows.
Dropping it would widen the search to the whole library while still looking like
it applied the constraint, so the mention is **re-encoded as a visual clause** and
a warning is raised. Letting the vector model have a guess is recoverable;
discarding what the user typed is not.

### Places named without a marker

`北京 猫` and `tokyo cat` are how people actually type, and the analyzer needs a
locative marker to recognise a place. The gazetteer lives on the engine side of
the boundary, so the engine does a second pass: the longest **exact** gazetteer
match inside a clause becomes the location filter and is removed from what the
model sees. `gazetteer.resolveExact` exists for this — `resolve` matches "北京"
inside "北京烤鸭" by prefix but cannot say *which* characters matched, so the rest
of the clause would be silently discarded.

Known false-positive class, documented rather than hidden: a place name embedded
in a longer common word (大理石 contains 大理, 长春花 contains 长春). The cost is a
needlessly narrowed result set; detecting it properly needs a language model,
which is the thing being avoided.

### Two analyzer bugs this phase found

**`2023年拍的猫` sent `拍的猫` to the text tower.** The camera verb sits
mid-string when the suffix stripper runs and only becomes leading *after* the date
is extracted, so it was never removed. A model asked about "拍的猫" is being asked
about a shutter action.

**`2023年拍的照片` was not metadata-only.** It encoded the clause "拍" and ran a
vector search to answer a question about a year.

### The test suite is mutation-checked

46 passing tests prove nothing if they cannot fail. Five deliberate breakages were
introduced and each was caught:

| mutation | failures |
|---|---|
| AND uses `max` instead of `min` | 3 |
| negation never rejects | 1 |
| score floor removed | 6 |
| candidates scored without the filter | 4 |
| unresolved place dropped | 1 |

### Measured

Text tower stubbed, so no model timing here. Real-model end-to-end latency is a
Phase 11 benchmark item.

### Similar-image search

`engine.search(similarTo:limit:)` is the one search that never touches the text
tower: the query vector is the reference asset's own stored row, so "more like
this" is one dot product per candidate against a vector already in the matrix.

Reading the vector back rather than re-encoding the image is not a shortcut. The
stored row is what every other search compares against, so using it puts the
reference and the results in the same space by construction; re-encoding would
introduce a second, slightly different vector (float16 storage alone moves a unit
vector by ~1.65e-5) and the same search could return a different order a moment
later. The reference is excluded from its own results -- otherwise it always ranks
first at 1.0, and the feature looks broken in exactly the way it looks when it
works.

No metadata filter is applied: "more like this" is a claim about appearance, and
narrowing it by date or place answers a different question.

## The offline gazetteer (Phase 8)

`PhotoVault/Search/OfflineGazetteer.swift` + `GazetteerData.swift`.
`python verify_siglip2.py geo` — **39/39**. 252 places: 42 province-level
divisions, 127 cities, 43 countries, 40 landmarks.

### A radius, not a polygon

A real boundary dataset would answer "was this photo taken in 朝阳区" exactly. It
would also be tens of megabytes, need a licensing review, and be wrong in a
different way at the edges. A centre plus a kind-appropriate radius is coarse, but
its error is *predictable*: it over-selects near a boundary rather than silently
excluding a photo ten metres outside a line nobody can see. The radius comes from
`PlaceKind`, because the useful granularity is a property of what a place *is* —
a landmark is not a province.

### Failing to resolve is reported, never silently ignored

The analyzer extracts any place-like mention, including ones no gazetteer knows
(`在海边拍的猫`). Dropping the filter in that case would quietly widen the search
to the whole library **while still looking like it applied the constraint**. So
resolution returns `.unknown(name)` and the caller must decide; the test asserts
an unknown place yields *nothing* rather than everything.

### Data provenance — the honest limitation

Coordinates are **hand-curated city-centre values to roughly 10 km**, not survey
data and not an imported dataset. That is well inside the search radius for a city
or landmark, but it is not authoritative. The alternative — shipping a large set
of coordinates that cannot be checked — would be worse, because a wrong coordinate
does not fail, it silently returns photos from the wrong place.

The trade is made explicit: a smaller set that is right, plus a loader that
accepts a bigger dataset unchanged. `OfflineGazetteer(entries:)` takes an array,
so replacing `GazetteerData` with real data touches no logic.

Sampling against public sources confirmed Interlaken at 46.6833/7.85 vs the
shipped 46.6863/7.8632 — within ~1 km. Everything else remains unverified against
an external reference.

### Three checks that catch wrong coordinates without a reference

Hand-entered data needs verification that does not depend on my own recall:

1. **Every China entry must lie inside China's bounding box.** A transposed pair,
   a sign slip or a value from the wrong city almost always leaves the country.
2. **Distances between ten well-known city pairs** (北京–上海 1067 km, 伦敦–巴黎
   344 km, 纽约–伦敦 5570 km, …) within 8%.
3. **Each province's centre must contain its identically-named city.**

### Two bugs this phase found

**The antimeridian clamp silently dropped half the box.** `longitudeRange`
computed `lower = max(-180, …)` and `upper = min(180, …)`, which keeps the
interval valid but *discards everything on the far side of the line* — a search
near Fiji would have missed every photo across it. Now anything crossing ±180 (or
wider than the globe) becomes the full range: over-selecting is recoverable,
missing is not.

**`New York` was split at the space into the place "New".** The analyzer assumed
a place is the first word and the rest is the subject, which is right for
`在上海 咖啡` and wrong for every multi-word name. Where a name ends is a *lookup*
question, not a grammar one: the analyzer now returns the whole mention and the
gazetteer takes the longest resolvable token prefix, then the longest character
prefix.

The gate that stopped "in a meeting room" being read as a place was requiring
capitalisation, which also rejected "in new york" — which users type. It now
rejects a leading **determiner** instead, and lets the gazetteer be the authority
on what is really a place.

## OCR and hybrid text search (Phase 7)

`PhotoVault/Search/PhotoTextRecognizer.swift` runs Vision on-device, and
`SearchTextNormalization.swift` is the single definition of what "the same text"
means. `python verify_siglip2.py ocr` -- **29/29**.

### `.fast` is not a cheaper `.accurate`

Measured: `.fast` supports **6** recognition languages and `zh-Hans` is not among
them; `.accurate` supports **18**. For a Chinese photo library there is no fast
path at all — asking for `.fast` does not degrade gracefully, it returns nothing
for Chinese text.

That directly constrains the Phase 10 thermal strategy: **OCR is the one stage
that cannot be stepped down a level when the device gets hot.** The correct
degradation is to defer OCR, not to lower its quality. A "degrade everything one
notch" policy would silently stop indexing Chinese receipts while still looking
like it was working.

Language support is queried at runtime, not hardcoded. Requesting a language the
platform lacks makes Vision *throw*, failing the whole recognition rather than
skipping one language — so the preferred list is intersected with what is
actually installed, and a device with only English still works for English.

### Two FTS paths must agree on the same string

Chinese OCR output frequently has no spaces at all, which is precisely where a
normalisation mismatch would hide: a query matching through trigram `MATCH` but
not through the `instr()` fallback would appear or vanish depending on its
*length*. Both paths now share `SearchTextNormalization`, and the test drives the
whole chain on **recognised** output rather than on strings typed by hand.

Note the deliberate split: the search index folds case, the **tokenizer must
not** (SigLIP2 distinguishes `CAT` from `cat`). Those are different jobs —
applying the model's convention to the index would be a category error, and the
store's `normalizeForSearch` now documents the distinction rather than repeating
the logic.

### Measured

Recognition on rendered text: **P50 68 ms** on a small clean image (macOS). The
first call costs ~380 ms while the model loads. Real photographs will be slower;
the numbers here bound the plumbing, not the device cost.

Recognition quality on clean synthetic text was high — `发票 报销凭证 2023年5月`,
`登机牌 Boarding Pass 北京到上海` and `微信聊天记录 明天下班一起吃饭` all came
back intact, and `12345` from an invoice number survived language correction.

## The query analyzer (Phase 6)

`PhotoVault/Search/QueryAnalyzer.swift` turns a natural-language query into a
structured plan. `python verify_siglip2.py query` -- **64/64**.

### The design principle: extract only what the model cannot express

The model understands photos; the analyzer understands what the user is asking
for. Those are different jobs, and the boundary is the whole design.

| the vector model cannot express | extracted into |
|---|---|
| a date or range | `dateFilter` |
| a place | `locationQuery` |
| logical negation | `negativeVisualClauses` |
| exact text | `ocrTerms` |
| media kind, favourites | `mediaFilter` |
| a count | `countConstraint` |
| "and" vs "or" | `combine` + multiple clauses |

Everything else is passed to the model **close to verbatim**. Stripping particles
and rewriting phrasing feels like doing more, but SigLIP2 tokenizes Chinese
natively and was trained on text like this — removing words it understands is a
loss, not a cleanup. The extra machinery belongs in the engine, not in mangling
the prompt.

### AND and OR are different maths

`狗和沙滩` means every clause should match; `狗或猫` means either may. A cosine
score can express both — `.all` takes the minimum per-clause score (satisfy the
weakest clause), `.any` takes the maximum (best clause decides) — but only if the
analyzer distinguishes them, which is why `combine` is part of the plan.

### Negation cannot be a cosine

`不要发票` must *remove* photos. A similarity score cannot express absence, so
negative clauses are carried separately and the engine rejects candidates scoring
above a ceiling against them. Folding the negation into the positive text
(`"不要发票"` as one visual clause) is what the first implementation did, and it
returned exactly the photos the user excluded.

Two traps found by testing:

- **Negation appears mid-clause.** `海边的狗不要其他人` is one clause with the
  marker in the middle. Prefix-only detection made the whole string a positive
  visual query, so the negation did nothing and the results looked plausible.
  Negation is now split out wherever it appears.
- **Bare `不` is not a safe marker.** It is a prefix inside `不错`, `不同`,
  `不清晰`, so treating it as negation splits `一张不错的照片` into a positive
  `一张` and a negative `错的照片`. Only unambiguous multi-character forms are
  matched; dropping a rare real negation beats mangling a common positive query.

### Places: recognise the grammar, resolve with the gazetteer

The analyzer extracts a place *mention*; it does not know coordinates. That split
matters because the gazetteer is finite (Phase 8), and an analyzer that only
recognised places present in the list would silently ignore everything else.

English prepositions are promiscuous — `in` marks a location in "in Beijing" and
an ordinary description in "in a meeting room". Requiring what follows to look
like a proper noun is what stops the analyzer reading
`a whiteboard with diagrams in a meeting room` as a query about the place
"a meeting room", which is exactly what it did before the check existed. The
locative marker can also sit mid-string: in `在北京拍的猫` the place is 北京 and
`猫` is the subject, so splitting only on trailing suffixes produced the place
"北京拍的猫" and no subject at all.

### Dates

`now` and `calendar` are **injected**, not read from the environment: a test that
says "last month" must not change meaning depending on when it runs. `最近7天`
is deliberately a rolling window rather than a calendar week — users notice the
difference.

A bare four-digit number is only a year when it stands alone or takes a `年`
suffix, so `2001太空漫游` keeps its meaning.

## The Swift text pipeline (Phase 5)

`PhotoVault/Search/SigLIP2TextEncoder.swift` runs the converted text tower from
Swift. `verify_siglip2.py textencoder` runs the **whole Swift chain** — Swift BPE
tokenizer then Core ML — against the PyTorch reference on the same 32 strings.

This closes a gap the other tests structurally cannot. The tokenizer test proves
the Swift port matches sentencepiece; the conversion test proves the Core ML graph
matches PyTorch. Neither ever runs the two Swift halves *together*, and the things
that can go wrong in the glue are exactly the ones neither would see.

### The measured cost of quantisation

Same 32 queries, cosine against the PyTorch reference:

| model | min cosine | mean | P50 encode |
|---|---|---|---|
| fp32 | **1.000000** | 1.000000 | 14.6 ms |
| fp16 | 0.999998 | 1.000000 | 9.4 ms |
| **w8 (shipping)** | 0.998961 | 0.999569 | 9.1 ms |

FP16 is effectively bit-exact. W8 costs ~1.0e-3 in the worst case, on a
whitespace-only query that carries almost no information. The gate is 0.998,
calibrated just below that rather than guessed, so a real regression is caught
without mistaking quantisation noise for one. The *product* gate is nDCG@20 loss
(§6 of the plan), which is a different measurement — embedding cosine is a proxy.

### Two traps this test exists to catch

**Case folding.** The HuggingFace tokenizer wrapper reports `do_lower_case=True`
for this checkpoint. The artifact does not fold case: `CAT`, `Cat` and `cat` map
to three different ids, and the reference scores cos("CAT", "cat") = **0.8616**.
The config flag states an intent the pipeline never acts on.

`convert_siglip2.py` was writing that flag straight into `model_manifest.json`, so
the manifest asserted something false about the artifact — and any client that
believed it would lowercase its input and silently stop matching the model it was
converted from. The manifest now derives `doLowerCase` by **probing the artifact**
(`_empirical_case_folding`), which cannot be fooled by a stale config value. The
harness asserts the pipeline keeps the variants distinct, and the fixture itself
refuses to build if the reference ever collapses them.

**Padding is not cosmetic.** The model has no attention mask and pools the **last
position** — which for a short query is a pad token. Passing fewer than 64 tokens
would change which position is pooled and produce a different embedding than the
reference. `SigLIP2TextEncoder` owns the truncate-and-pad step so callers cannot
pass an unpadded sequence.

### Latency

Warm query encode is **P50 9.1 ms** on macOS CPU/GPU. The first prediction after
load costs ~7.7 s (Core ML specialisation), which is why the encoder is built once
at startup rather than per search.

## The Metal exact-search kernel (Phase 4)

`PhotoVault/Search/EmbeddingSimilarity.metal` + `MetalSimilaritySearch.swift`.

    python verify_siglip2.py metal          # 31/31 checks

One thread per row, `float4` accumulation, exact dot product. Rows are unit length
and the query is normalised before dispatch, so the dot product *is* the cosine
and there is no per-row division. A scalar tail covers dimensions that are not a
multiple of four — the embedding dimension comes from the model manifest and is
never assumed to be 768.

**The matrix is mapped, not copied.** The rows are wrapped with
`makeBuffer(bytesNoCopy:)` over the existing mmap, so the GPU reads file-backed
pages directly. Copying 147 MiB per search would cost more than the search and
would put a second full copy of the library in memory — the exact thing Float16
storage was chosen to avoid. The mmap is therefore a stored property; if it were
a local the buffer would point at freed memory.

**Only the dot products go to the GPU.** Selecting top-k from 100k floats is one
linear pass, well under a millisecond; a GPU reduction plus dispatch plus
readback to save that would be a loss.

### Accuracy, measured

Both paths are checked against a dot product accumulated in **Double**. Residual
error is 3e-7 at the worst — pure Float32 rounding:

| dimension | GPU vs Double | CPU vs Double |
|---|---|---|
| 768 | 3.0e-7 | 1.7e-7 |
| 13 | 9.4e-8 | 1.5e-7 |
| 4 | 9.2e-8 | 8.7e-8 |
| 1 | 0 | 0 |

Getting to that number required fixing the reference twice, and both mistakes are
instructive:

1. The first reference summed in **Float32** — the least accurate of the three
   implementations — and "failed" the GPU at 2.7e-4. Summing 768 terms in Float32
   cannot do better than ~1e-4, and blocked accumulation (what the GPU and BLAS
   both do) beats sequential. The reference was measuring its own error.
2. The second used the original **Float32 rows** rather than the Float16-quantized
   values the matrix actually stores, and "failed" *both* paths at 2.7e-4 for
   dimension 4. Six terms of Float32 rounding cannot produce 2.7e-4 (epsilon is
   1.2e-7), which was the tell that the target was a value nothing could produce.

That second number is worth keeping: **Float16 storage is the dominant error term
in the pipeline, not the summation order.** How large it is depends on the
component magnitudes — for unit vectors, ~1.65e-5 at dimension 768 but ~2.7e-4 at
dimension 4, where components are large. At 768 it is two orders of magnitude
below any gap that could reorder two distinct photos.

### Ordering parity is not exact, and cannot be

Exactly-equal scores break identically, because both paths call the same
`selectTopK`. Two scores differing by less than Float32 accumulation error can
still order differently — the underlying floats genuinely differ between GPU and
CPU. That is inherent, not a defect. The test asserts the precise claim: any
disagreement is confined to scores that are indistinguishable at this precision.

### Is the GPU worth it?

On an M1 it is only **~1.2-1.3x** faster than Accelerate (7.5 ms vs ~9 ms), because
Apple's BLAS is already excellent and the kernel is memory-bandwidth bound. Both
are ~50x inside the 500 ms budget. The honest justification is not raw speed: it
is that the scan does not compete with the UI for CPU, and it keeps headroom on
devices where the CPU is thermally throttled — which is exactly the Phase 10
degradation scenario. The Accelerate path is kept, and is what the parity tests
are built around.

## The indexing pipeline (Phase 3, PhotoKit-free)

`PhotoVault/Search/PhotoIndexPipeline.swift` fills the index;
`PhotoVault/Search/PhotoKitIndexSource.swift` is the PhotoKit glue.

    python verify_siglip2.py pipeline       # 36/36 checks

PhotoKit is absent from these tests, and that is what makes them worth running.
The pipeline's job is not to talk to PhotoKit -- that is Apple's code -- but to
decide when to stop, what to retry, what to defer when the device is hot, and to
guarantee that a superseded run cannot write. That is pure logic. The store is
real, so "resume after the app is killed" is tested by throwing the coordinator
away and building a new one over the same database.

### OCR is deferred, never downgraded

Vision's `.fast` recognition level supports six languages and `zh-Hans` is not
one of them. So "step OCR down when the device is hot" is not a lower-quality
OCR, it is **no OCR for Chinese** -- it would stop indexing every Chinese receipt
while still looking like it was working. The only honest degradation is to leave
the work for later.

Embedding is the opposite case: it degrades gracefully and is the whole point of
the feature, so it continues under `.serious` thermal pressure and Low Power Mode
and stops only at `.critical`.

| conditions | batch | embedding | OCR |
|---|---|---|---|
| nominal | 32 | yes | yes |
| `.serious` thermal | 16 | yes | **deferred** |
| Low Power Mode | 16 | yes | **deferred** |
| `.critical` thermal | 0 | no | no |

### A step must be told which run it belongs to

`step(generation:conditions:)` takes the generation as an argument. Comparing
against `self.generation` at entry would be checking a value against itself -- a
synchronous function cannot observe a change that happens while it runs -- so the
"a superseded run cannot write" guarantee would have been both untestable and
unenforced. A stale batch now returns `.superseded` and writes nothing.

### iCloud-unavailable is not failure

An undownloaded iCloud original is a healthy photo that is not on this device
yet. Counting it as a failure would park it for hours after a few attempts, so it
stays `pending` with a bumped `next_retry_at` (`deferAsset`).

**This is where a real store bug surfaced.** `pendingAssetIDs` originally read
`next_retry_at` only for `failed` rows and returned `pending` rows
unconditionally, which made `deferAsset` a no-op: the same photo was selected
again immediately, and on a fresh device -- where many assets are cloud-only --
that is an unbounded retry loop burning CPU and battery. The test showed it as
`unavailable=98` (it gave up after 100 iterations). The predicate is now
`status IN (pending, failed) AND (next_retry_at IS NULL OR next_retry_at <= ?)`.

### Progress is throttled to ~4/s

Publishing once per asset rebuilds the entire SwiftUI tree several times a second
on a 100k index, which is the difference between a usable app and a frozen one.
Phase changes and completion always publish; per-asset progress does not.

## The metadata index (Phase 3)

`PhotoVault/Search/AIPhotoSearchStore.swift` owns `AIPhotoSearch.sqlite`: which
assets are indexed, their embedding slot, the metadata needed to filter without
asking PhotoKit, and OCR text.

    python verify_siglip2.py index          # 69/69 checks

Kept in a **separate database** from `PhotoIndex.sqlite`. The existing index is
verified and load bearing; the AI index can be dropped or schema-bumped with zero
migration risk, which is worth one extra file.

### The swap-remove contract

This is the part that can be silently, catastrophically wrong. The matrix keeps
itself dense by moving the *last* row into the hole, so the asset that owned the
last slot now lives somewhere else and its SQLite row must be updated in the same
transaction. Get it wrong and search returns one photo's vector for another photo
— a wrong result, not an error, invisible to every test that only checks counts.

The test therefore does not check counts alone. After each deletion it reads the
matrix back and asserts **every asset's slot still holds its own vector**, using
vectors whose first component identifies the asset.

Two ordering constraints, both learned the hard way:

1. **Release the departing slot before relocating the moved row.** The unique
   index on `embedding_slot` rejects the relocation otherwise, because for one
   statement both rows claim the same slot. This actually fired on the first run
   — the unique index earned its place immediately.
2. **Delete in descending slot order.** Each swap-remove then moves the current
   last row, and already-processed slots sit below the shrinking boundary.
   Any other order can relocate a row that is itself awaiting removal.

`validateSlotConsistency()` re-checks matrix count against SQLite after a batch
so this class of bug surfaces in a batch, not in the UI.

### Candidacy is "has a vector", not "status == ready"

An asset that was embedded and later failed a *re*-index still holds a valid
vector; excluding it on status would drop a searchable photo for no reason. The
candidate query also requires `model_version` to match, because ranking a query
vector against a vector from a different model gives confidently wrong results
rather than an error.

### FTS5 and the 2-character problem

`tokenize='trigram'` is chosen because it matches *inside* a token — a word
tokenizer indexes `boardingpass2023` as one token and finds nothing for `dingp`.
But trigram **cannot match queries shorter than three characters**, and 2-character
Chinese terms (发票, 报销) are a large share of real searches. The `instr()`
fallback is not optional.

Both paths read the same standalone FTS table, so the normalized text is stored
once and there is no external-content trigger dance. A test asserts that a
mid-token substring matches for a ≥3-character term, so a silent fallback to
`instr` cannot make a dead FTS index look healthy.

Text is case- and width-folded on the way in, so `instr` and `MATCH` agree on
what "contains" means.

### Connection discipline

Reads use a second connection so they see the last committed snapshot instead of
queueing behind a rebuild transaction that can run for tens of seconds. That
connection is opened **READWRITE on purpose**: a READONLY connection cannot
perform WAL recovery, so after an unclean shutdown every read would fail —
surfacing as a permanently empty library rather than an actionable error. Reads
additionally fall back to the write connection, because a read must not fail
merely because the second connection is unhappy.

`stepAndReset` reports errors from the **write** connection. Reading
`sqlite3_errmsg` off the read connection turned a genuine UNIQUE constraint
violation into `"not an error"`, which is worse than no message at all.

## The tokenizer, and why it is a port rather than a dependency

Phase 2 also has to produce the **text** side of the model, which means tokenizing
Chinese and English queries on device with output identical to Python. Two
obvious routes are both bad: vendoring `sentencepiece` means building a C++
library for iOS, and shipping `tokenizer.json` means parsing 34 MB of JSON.

So the tokenizer is a port, and it lives in three files:

| file | role |
|---|---|
| `siglip2_tokenizer.py` | the **executable spec** — a direct port of sentencepiece `src/bpe_model.cc` |
| `build_tokenizer_corpus.py` | generates the adversarial corpus the port is judged on |
| `tokenizer_test/main.swift` | compiled with the Swift source to diff it against Python |

Shipped app code is `PhotoVault/Search/SigLIP2Tokenizer.swift`, backed by
`build/tokenizer-v1.bin` (5.3 MB), a compact artifact generated from
`tokenizer.model`.

    ./.venv/bin/python verify_siglip2.py tokenizer --rebuild

That is the whole gate: it regenerates the corpus, artifact and ground truth,
diffs the Python port against real sentencepiece, compiles the Swift, and diffs
the Swift against Python. Current result: **9/9 checks, 0 mismatches on 6194
adversarial strings, 32 µs per realistic query.**

### What the checkpoint's tokenizer actually is

Read from the file, not assumed:

| field | value | consequence |
|---|---|---|
| `model_type` | 2 (BPE) | merge by **score**, not unigram Viterbi |
| `precompiled_charsmap` | **empty** | no NFKC, **no case folding** (so `CAT` ≠ `cat`) |
| `name` | `identity` | normalization is a no-op |
| `add_dummy_prefix` | **False** | no leading `▁` is inserted |
| `remove_extra_whitespaces` | False | runs of spaces are preserved |
| `escape_whitespaces` | True | the entire normalizer: `' '` → `▁` |
| `byte_fallback` | True | unknown text becomes `<0xXX>` pieces |
| special ids | unk 3, bos 2, eos 1, pad 0 | |

The empty `precompiled_charsmap` is the fact that makes this port small: it
removes the double-array trie, which is otherwise the genuinely painful part.

Two things a from-scratch implementation gets wrong, both worth reading before
touching the Swift:

1. **The initial split is not "one character each."** sentencepiece builds its
   prefix matcher from the **USER_DEFINED** pieces only — 245 of them here
   (`<start_of_turn>`, newline runs, `▁▁`, HTML tags, `[toxicity=0]`, …). One
   character is only the fallback. Symbols matched this way are *frozen* and
   never merge.
2. **Merging is by piece score, not training order.** This is not classic
   rank-based BPE, so re-deriving a merge list gives different tokens — a
   failure that produces plausible-looking ids and no error anywhere.

One deliberate simplification: the reference uses a priority queue and discards
stale entries by re-checking piece lengths. The Swift recomputes the best valid
pair each round, which is equivalent for query-length input and removes a class
of heap-ordering bugs. `tokenizer_test/main.swift` is what makes that safe to say.

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

## Shipping the model (D5)

The W8 build is **364 MB** (89 MB vision + 270 MB text + 5 MB tokenizer); FP16 is
715 MB. Both are reproducible from `requirements-lock.txt` plus
`convert_siglip2.py`, so they are **not in git** -- `PhotoVault/Models/` is
ignored and populated by a script.

    python tools/models/install_models.py            # copies W8 into PhotoVault/Models
    python tools/models/install_models.py --check     # report only
    python tools/models/register_search_sources.py    # registers it as a resource

The consequence is real and stated rather than hidden: **a clean clone cannot
build a working app until the install step has run once.** The build does not
fail without it -- no Swift source references these files at compile time -- so
search simply has no model, and `SearchModelResources` reports exactly which file
is missing and which command installs it, instead of crashing on a nil URL.

Verified: the bundle contains `SigLIP2Vision.mlmodelc` (89 MB),
`SigLIP2Text.mlmodelc` (270 MB), `tokenizer-v1.bin` and
`SearchModelManifest.json`; app total **384 MB**. The `.mlmodelc` layout
(`coremldata.bin` / `model.mil` / `weights`) confirms `coremlc` genuinely
compiled them rather than the package being copied.

### The bundled artifacts are tested, not assumed

    python verify_siglip2.py bundle      # 16/16 checks

Every other mode here checks the *pipeline*: Python reference, converted
mlpackage, Swift port. All of them passed while the app still had no model in it,
because "the mlpackage is correct" and "the app can load what shipped" are
different claims. This mode loads the `.mlmodelc` files out of the built
`PhotoVault.app` and runs them.

The decisive check:

    cos("CAT", "cat") = 0.8610     (reference 0.8616)

That one number proves the bundled tokenizer and the bundled text tower are the
**pair** that was validated. A mismatched vocabulary, a case-folding normalizer,
or a stale model would each move it -- and this tokenizer deliberately does not
fold case (`CAT` and `cat` are tokens 29492 and 4991). Measured alongside it:
vision norm 1.0007458 and text norm 0.9997030, confirming the conversion's baked-in
normalization survived packaging.

## Registering the search sources (D4)

    python tools/models/register_search_sources.py --check   # report only
    python tools/models/register_search_sources.py           # apply

`PhotoVault.xcodeproj` uses **explicit** `PBXBuildFile` references --
`PBXFileSystemSynchronizedRootGroup` appears zero times -- so a file dropped into
`PhotoVault/` is not compiled until it is listed in the Sources phase, referenced
from a valid file reference, and placed in a group. The script does all of that
and is idempotent.

Verified result: **34 object files** (20 original + 14 search), and
`default.metallib` in the bundle containing the `embedding_dot_fp16` kernel.

### A dangling file reference is not an error

The first version of this script allocated the file-reference id **twice**: once
while building the `PBXBuildFile` line and again in the reference loop. The build
files therefore pointed at `B1...40-54` while the references were created as
`B1...55-69`.

Xcode did not complain. The build reported `** BUILD SUCCEEDED **`, no file was
compiled, and the object count stayed at 20. **A build file whose `fileRef` does
not resolve is silently dropped, not diagnosed** -- so a green build is not
evidence that a file is in the target.

The lesson generalises: after registering sources, check for the *object files*,
not the exit status. The script now verifies before writing that every build
file resolves and that each reference id appears at least three times
(definition, group entry, build-file reference).

### Two encoders are locked, not just marked Sendable

`SigLIP2VisionEncoder` and `SigLIP2TextEncoder` each reuse **one** input buffer
(`inputArray`/`inputPointer`). Two concurrent encodes would interleave the copy
and the prediction, so one photo would be embedded from another photo's pixels
-- silently, because both tensors are valid. Both now hold an `NSLock` around the
whole fill-then-predict cycle and declare `@unchecked Sendable` on that basis.

The text encoder compiled without the lock because it never declared `Sendable`;
the compiler was silent about an identical latent bug. Serialising is also the
honest model of the hardware: there is one ANE.

### Type names that collided with the existing index

The app already had a `PhotoIndexProgress` (the unsorted-photo index, with
`scanningAssets` / `scanningAlbums` phases). The pipeline's types were renamed to
`PhotoSearchIndexProgress`, `PhotoSearchIndexState`, `PhotoSearchIndexStep`,
`PhotoSearchIndexConditions`, `PhotoSearchIndexPolicy` and
`PhotoSearchIndexCoordinator`. Standalone typechecking never caught this because
the new files were never compiled alongside the existing ones.

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

## The search UI (Phase 9)

    xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault \
      -configuration Debug -destination 'generic/platform=iOS' build

The sidebar's "智能搜索" row opens `SmartSearchScreen`. It does **not** reuse
`PhotoSearchResultsScreen`, which filters *album titles*; this searches *photo
content*, and conflating the two makes "did I match an album or a photo?" unclear.

Three decisions worth knowing:

**Results are `[PHAsset]`, not `PHFetchResult`.** PhotoKit does not preserve the
order of an identifier fetch, and the ranking is the entire output of a search.
The result set is bounded by `maximumResults`, so materialising it is safe.

**Opening a result resolves the index inside the fetch result.** `PhotoViewerView`
displays `assets.object(at: initialIndex)`, while `initialAssetIdentifier` only
seeds the first frame's preview. Passing the rank directly would open whichever
photo PhotoKit happened to put at that position -- the wrong picture with the
right thumbnail, which is the hardest kind of bug to notice. Known limitation:
swipe order within the viewer follows PhotoKit, not relevance.

**The index is filled only from this screen.** 100k photos is hours of work;
starting it at launch would make a user who never opens search pay for it.

### The coordinator is locked, and that was a real race

`PhotoSearchIndexCoordinator` runs its batch loop off the main actor (image
decoding plus inference is seconds per batch) while `pause()` arrives *from* the
main actor and the UI reads `state`/`progress`. Swift 6 rejected it outright with
`sending 'coordinator' risks causing data races`, and it was not a false positive:
a mid-batch pause could be lost, or progress read half-updated.

All four mutable fields now sit behind an `NSLock`, `onStateChange` fires *after*
the lock is released so a re-entrant callback cannot deadlock, and `step()`
accumulates into a **local copy** that is committed once at the end -- the lock is
never held across decoding or inference, since that would block `pause()` on the
main thread for seconds.

Verified with Thread Sanitizer: the whole pipeline suite compiled with
`-sanitize=thread` passes **42/42 with zero data-race reports**, including six new
concurrency checks.

### Check the dylib, not the stub

A prior round concluded the search stack was being stripped by the linker, based
on finding zero distinctive strings in `PhotoVault.app/PhotoVault`. That check was
aimed at the wrong file. With Xcode 16+'s `ENABLE_DEBUG_DYLIB`, that path is a
**91 KB launcher stub with 105 symbols**; the real code is in
`PhotoVault.debug.dylib` (**12 MB, 28,124 symbols**), where `SmartSearchScreen`
(231), `AIPhotoSearch` (370), `QueryAnalyzer` (194) and `SigLIP2VisionEncoder`
(60) are all present.

When asking "did this module make it into the product?", name the product
correctly first -- in Debug, the main binary may only be a shell.

## Auditing the on-device guarantee (Phase 11)

    python verify_siglip2.py privacy      # 11/11 checks

The constraint is that no photo, embedding, OCR text or query ever leaves the
device. That is easy to state and easy to break: one `URLSession` added while
debugging is all it takes. So this gate reads the **source** of `PhotoVault/Search`
rather than trusting behaviour:

* no networking API (`URLSession`, `NWConnection`, `dataTask`, `uploadTask`, ...)
* no remote endpoint literal (`http://`, `https://`)
* only system frameworks imported -- zero third-party dependencies
* **nothing in the search stack writes to a log**, since photos, OCR text and
  queries are exactly what must never reach one
* the embedding matrix is `isExcludedFromBackup` (150 MB of derived data should
  not be pushed into iCloud)
* `THIRD_PARTY_NOTICES.md` carries the full Apache-2.0 text, names the shipped
  model, and discloses that the files were modified

It was mutation-tested: injecting `URLSession`, an `https://` URL and a `print(`
into `QueryAnalyzer.swift` produced three precise failures; reverting restored a
pass. A first version also flagged `modelFingerprint(` as a log call -- hence the
word-boundary match. **A check that cries wolf gets ignored, which is worse than
no check.**

### Restart is not the same as resume

`pipeline` also covers §82's "index resumes after a restart" -- a different claim
from pausing and resuming inside one coordinator. After the first run is killed,
a **new store handle and a new coordinator** reopen the same paths; the second run
must embed only the remainder, not the library. It does.

That test initially failed, and the bug was the test's: it hardcoded 50 assets
while `makeStore()` seeds 20 of its own, so 70 existed. Expectations are now read
from the store at runtime. **A hardcoded expectation disguises the test's own
error as a product defect.**

### Release

`-configuration Release` builds clean (380 MB bundle, 7.1 MB binary, 17,686
symbols) and carries **zero** occurrences of the DEBUG log paths
(`PhotoVaultLaunch.log`, `PagerDiagnostics.log`, `lan-folder.log`) -- the
diagnostics are compiled out.

## Measured on the device (iPhone 15 Pro)

Everything above was measured on an Apple M1. Four questions could only be
answered on real hardware, and a launch argument answers them with no UI
interaction:

    xcrun devicectl device process launch -d <id> com.misswell.PhotoVault --pv-ai-selfcheck
    xcrun devicectl device copy from -d <id> --domain-type appDataContainer \
      --domain-identifier com.misswell.PhotoVault \
      --source Library/Caches/PhotoVault/AISearchSelfCheck.log --destination /tmp/report.log

The report holds only counts, timings and booleans -- no photo data. It is
`#if DEBUG`, so none of it exists in a Release build, and it lives outside
`PhotoVault/Search/` because the `privacy` gate asserts that the *search stack*
never writes to a log.

### iOS ships FTS5 **with the trigram tokenizer**

```
sqlite version:     3.54.0
FTS5 compiled in:   true
trigram tokenizer:  true
search path:        FTS5 MATCH (trigram)
```

Not just DDL acceptance: create, insert Chinese text, `MATCH '海边'` returned the
row. So hybrid OCR search can use `MATCH` and `instr()` is belt-and-braces rather
than the only path. This question is **unanswerable off-device** -- Apple builds
its own SQLite, and no version number implies the compile options.

### Model loading is a one-time cost, and reinstalling resets it

| | cold (first ever) | warm |
|---|---|---|
| vision tower | **5502 ms** | **79-178 ms** |
| text tower | **21292 ms** | **298 ms** |

First load is ~27 s; afterwards ~0.4 s -- **70x faster**, from the on-disk ANE
program and weight cache. **Reinstalling the app clears it**: a fresh install
immediately returned to 4485 / 23582 ms. So the 27 s is once per *install*, not
per launch. That is why `SmartSearchModel.prepare()` waits for the search screen
rather than loading at app launch.

### Vision encode varies 3.3x, and the thermal explanation is wrong

| run | vision encode P50 | thermalState | peak memory |
|---|---|---|---|
| 1 | 161.3 ms | -- | 143 MB |
| 2 | 529.2 ms | -- | 67 MB |
| 3 | 417.5 ms | -- | 138 MB |
| 4 | 185.4 ms | -- | 66 MB |
| 5 | **157.1 ms** | **serious** | 522 MB |

For a 100k library that is **4.4 h (fast) to 14.7 h (slow)**.

I first attributed 161 -> 529 ms to thermal throttling, on the evidence that
repeated runs slowed and cooling restored speed. Recording `thermalState` refuted
it: run 5 was the **hottest** (`serious`) and also the **fastest** (157 ms).
**That explanation is withdrawn.**

What survives: the variance is real and reproducible, and **`thermalState` does
not predict encode throughput**. The likely remaining explanation is that Core ML
switches placement between ANE and GPU -- the fast samples cluster at 157-185 ms
and the slow ones at 417-529 ms, which looks like two populations, not a
continuum. But the actual compute unit was not measured, so that stays a
hypothesis. The way to settle it is `MLComputePlan` (iOS 17+), which reports the
placement the model actually got.

The implication for Phase 10 is stronger than before, not weaker: an indexing
policy that adapts on `thermalState` alone is adapting on a value now shown to be
uncorrelated with throughput. It needs observed throughput instead.

Peak memory is 66-143 MB warm, but **522 MB on the cold first load** -- budget
against the latter if it matters.

### Also confirmed on device

* ANE available (`neuralEngine, gpu, cpu`)
* `cos("CAT","cat") = 0.8612` vs reference 0.8616 -- the bundled pair is correct
  on hardware, matching the 0.8610 the `bundle` gate measures on macOS
* text encode is **faster** on device than on M1 (2.8 ms vs 9.1 ms); vision
  encode is slower (157-529 ms vs 52.7 ms)
* OCR offers 3 languages including **`zh-Hans` and `zh-Hant`**
* the AI index database opens and migrates on device

Not yet done on device: end-to-end indexing (needs photo permission, which the
self-check deliberately does not request).

## The runnable benchmark (Phase 11)

    python benchmark_siglip2.py --mode coreml \
      --image-model out/SigLIP2ImageEncoder-w8.mlpackage \
      --text-model out/SigLIP2TextEncoder-w8.mlpackage \
      --label w8 --library-size 100000

Measured on the Apple M1 (a **floor**, not a device claim -- see the device
section above for the real numbers):

| W8, 100k x 768 | P50 | P95 |
|---|---|---|
| image encode | 9.87 ms | 10.27 ms |
| text encode | 9.19 ms | 9.64 ms |
| exact retrieval over 100k | **7.44 ms** | 10.92 ms |

The retrieval target is P50 < 500 ms / P95 < 1000 ms at 100k, so this is roughly
50x inside budget. Matrix footprint at 100k is 153.6 MB of float16.

### The quantization gate (spec section 6)

Spec section 6 accepts a quantized model only if nDCG@20 stays within 1.5% of
FP16. That is a gate, not a comment, so it is checked by re-running retrieval
quality from embeddings produced by each candidate:

    python benchmark_siglip2.py --compare \
      out/SigLIP2TextEncoder.mlpackage:fp16 \
      out/SigLIP2TextEncoder-w8.mlpackage:w8 --fixtures build/parity

| label | size | nDCG@20 | Recall@20 | MRR | relative loss |
|---|---|---|---|---|---|
| fp16 | 564.8 MB | 1.000000 | 1.0 | 1.0 | -- |
| **w8** | **283.3 MB** | **0.999393** | 1.0 | 1.0 | **0.061%** |

`worst nDCG@20 relative loss: 0.06%  (gate: <= 1.5%)` -- W8 passes with about
**25x margin**, which is why it is the shipping choice: it halves the download
(564.8 -> 283.3 MB for the text tower alone) for a quality difference far below
the threshold.

## Two bugs that only a real device could find

Both were invisible to every local gate -- 13 gates, several hundred checks, all
green -- and together made search work exactly once per install and then break
permanently.

### `FileHandle.truncate` moves the write offset on iOS but not on macOS

`createFile()` truncated to one page and then wrote the header "at the current
offset". On iOS that offset is the *new end of file*, so the header landed at
byte 4096 behind a page of zeros and the file grew to 8192 bytes. On macOS the
offset stays at 0 and the file is correct.

Pulled the file off the device to confirm:

```
size 8192                    (expected 4096)
0x0000: 00 00 00 00 ...      <- a whole zero page
0x1000: 50 56 45 4d 42 30 30 31 ...   <- "PVEMB001" is here
```

It failed in the worst way. The first `open` creates the file and never re-reads
it -- the header is still in memory -- so everything worked. Every later launch
parses the file, sees no magic, and throws `notAnEmbeddingFile`.

### `createFile()` wrote a zero checksum

Only `writeHeader()` set `header.checksum` before serializing; `createFile()`
called `serialized()` directly, and `EmbeddingHeader.init` leaves the checksum at
0. So a new matrix went to disk with a zero checksum and threw `headerCorrupt` on
the next open -- meaning fixing the offset alone would only have changed the error
message.

Both writers now go through one `mutating func serializedWithValidChecksum()`, so
no caller can forget. It cannot live inside `serialized()`: `computedChecksum()`
is built on `serialized()`, and that recursion segfaults.

### Why no local test caught either

* **Bug 1 was originally misdiagnosed here as an iOS-only Foundation
  difference. It is not.** Removing the fix and creating a matrix on macOS
  reproduces the identical bytes (8192, zeros at 0, `PVEMB001` at 4096), so the
  bug is platform-independent.
* The real reason every local test passed: **one `append()` silently repairs the
  file.** `grow()` calls `writeHeader()`, which uses `pwrite(..., 0)` at an
  explicit offset, so the header lands back at byte 0 and the file is valid
  again. Every pre-existing test wrote a row before reading, so all of them
  passed.
* The only unguarded case is a matrix that is created and **never appended to**
  -- a fresh install killed before its first embedding, or a library with no
  photos. That makes the bug broader than first reported, not narrower.
* Bug 2 needs that same empty matrix to reach `createFile()`.

The new regression checks assert the **bytes on disk** rather than "reopening
works", because on macOS reopening succeeds either way. `embeddingstore_test` is
now 38 checks.

A sweep for the same pattern (`truncate` / `seek` / `ftruncate`) found no other
occurrence: the rest either `seekToEnd` before appending or use `pwrite` with an
explicit offset.

### Recovery: a damaged matrix is rebuilt, not fatal

Both bugs left the store in a state it could never leave -- every later launch
opened the same bad file and failed identically, and only a reinstall cured it.
The matrix is derived data, so `openIfNeeded` now rebuilds it when the failure is
corruption (`notAnEmbeddingFile`, `unsupportedVersion`, `headerCorrupt`,
`shortRead`).

The rebuild also has to re-queue the rows. Slots are assigned by the matrix, and
a rebuilt one starts empty, so a row still carrying an old `embedding_slot` would
resolve to the wrong vector. Every affected row is cleared back to `pending`.

`dimensionMismatch` and `modelMismatch` are deliberately **excluded**: opening a
matrix with the wrong dimension or from another model must be rejected. That is a
tested contract, and the `index` gate caught an earlier, over-broad version of
this change with three failures -- rebuilding there would silently discard a
working index and hide a caller passing the wrong values. Environment failures
(full disk, permissions) are excluded too: the rebuild would fail identically.

`pipeline_test` is now 56 checks; it damages a populated matrix, reopens it, and
requires the store to come back empty, fully re-queued, and immediately writable.

### A model change rebuilds too

The model fingerprint is the manifest name, so shipping any new conversion
changes it. The app opened the store directly, which meant a new model would put
every existing user's search screen into a permanently failed state -- the same
shape of bug as the two above.

`open` keeps rejecting a mismatch (that is a tested contract). The app instead
calls `openRebuildingIfIncompatible`, which is a separate entry point so the
strict behaviour stays available. It reuses `rebuildEmbeddingMatrix`, so only the
vectors are discarded: `ai_asset` also holds capture dates, GPS and OCR text,
none of which are model-derived, and deleting the database would have forced a
full PhotoKit re-enumeration of the library. The `index` gate caught an earlier
version that deleted everything.

`index` is now 77 checks, including a regression that plain `open` still refuses
a different model.

## The score floor does not filter (measured, Phase 12)

`PhotoSearchConfiguration.minimumScore` was documented as removing "the long tail
of noise". Measured through the shipping pipeline over a 17-photo library, it
removes nothing:

```
"a red square"        -> 17/17 clear 0.02, mean 0.060
"mountain waterfall"  -> 16/17 clear 0.02, mean 0.044
```

Retrieved scores live in a ~0.05-0.14 band while the tail sits at 0.07-0.08, so
the floor is far below anything it could reject.

The value was left alone on purpose. The real discrimination is in the ordering
(for "green" the top hit scored 0.136 against a ~0.072 tail), and a floor high
enough to bite (~0.08) would cut into that same band and start returning nothing
for hard queries. Tuning it from 17 photos -- six of them solid-colour synthetic
images -- would only overfit; that needs labelled ground truth (D6).

If stronger filtering is ever wanted the mechanism must be *relative*: an
absolute floor cannot separate a 0.088 top hit from a 0.078 tail without
discarding the hit too.

## Limited Photo Access and denial (verified on the simulator)

Set the TCC row directly -- `auth_value` is the access tier: 0 denied, 2 full,
3 limited. `simctl privacy` has no limited option.

```
auth_value 3 -> photo access: limited   ... limited: true, index and search still work
auth_value 0 -> photo access: denied    ... typed accessDenied, app alive, existing index still readable
```

Both are handled as first-class states rather than crashes.

## End-to-end retrieval quality (`eval_retrieval.py`)

Every other check here measures a *component*. None answered "when I type this,
does the right photo come back first?" -- that needs a library with known
contents.

`make_eval_fixture.py` generates a deterministic labelled fixture (flat colour
fields, plus rendered words), `simctl addmedia` imports it, and the app's self-check
emits each ranking with the asset's original filename. `eval_retrieval.py` joins
the two and scores it.

```sh
python3 tools/models/make_eval_fixture.py --output /tmp/evalset
xcrun simctl addmedia <simulator-udid> /tmp/evalset/*.jpg
# launch the app with --pv-ai-selfcheck --pv-ai-selfcheck-index, then pull
# Library/Caches/PhotoVault/AISearchSelfCheck.log out of the data container
python3 tools/models/eval_retrieval.py <log> --require-precision 1.0 --require-recall 1.0
```

Measured on an iPhone 17 Pro simulator (iOS 26.3), 20-asset library:

```
query                  P@1    R@k     RR  top hit
a blue image          1.00   1.00   1.00  ok  photo2.jpg (0.1275)
a cyan image          1.00   1.00   1.00  ok  photo5.jpg (0.1445)
a green image         1.00   1.00   1.00  ok  photo1.jpg (0.1314)
a purple image        1.00   1.00   1.00  ok  photo4.jpg (0.1336)
a red image           1.00   1.00   1.00  ok  exiftest.jpg (0.1335)
a yellow image        1.00   1.00   1.00  ok  photo3.jpg (0.1332)
an invoice            1.00   1.00   1.00  ok  invoice.jpg (0.1632)
a passport            1.00   1.00   1.00  ok  passport.jpg (0.1578)
"INVOICE"             1.00   1.00   1.00  ok  invoice.jpg (1.0000)
"PASSPORT"            1.00   1.00   1.00  ok  passport.jpg (1.0000)

precision@1        10/10 = 1.0000
MRR                1.0000
```

The benchmark fails if it should: swapping one query's top two results drops P@1
to 0.8750 and MRR to 0.9375 and exits non-zero. `--require-recall` alone would
*not* catch that, which is why `--require-precision` exists -- recall is
order-insensitive, and demoting a correct answer from rank 1 is precisely the
regression a user notices.

### OCR vs appearance: two different queries

The fixture includes quotation-marked queries on purpose. Measured:

```
evalplan|an invoice|candidates=20|ocr=|clauses=1
evalplan|"INVOICE" |candidates=1 |ocr=INVOICE|clauses=0
```

Quoting is the documented exact-text request and the **only** phrasing that
populates `ocrTerms`. So `"INVOICE"` filters the library 20 -> 1 through Vision
OCR, while the unquoted `an invoice` leaves all 20 candidates and wins on
appearance alone (a white page with black marks looks like a document). Reading
the first as OCR evidence would be wrong; the `evalplan|` lines exist so that
distinction is visible rather than assumed.

### Scope

This is a **simulator fixture of rendered images**, not a device claim and not a
substitute for a real photo library. Absolute scores are not comparable to a real
library's. What it does establish is that the whole chain -- PhotoKit -> vision
tower -> embedding matrix -> query analysis -> OCR filter -> fusion -> ranking --
puts the right asset first, which no other check here does.

### Set logic against real photos (AND / NOT / OR)

`query` (64 checks) and `search` (58 checks) cover these rules on synthetic
input. `eval_retrieval.py` also runs them against photos whose contents are known,
where a negative clause has to out-score the configured ceiling against an actual
embedding.

```
evalplan|a red image or a green image |clauses=2|combine=any|neg=0
evalplan|a red image and a blue image |clauses=2|combine=all|neg=0
evalplan|a red image not a cyan image |clauses=2|combine=all|neg=1

a red image or a green image   exiftest 0.1335  photo0 0.1324  photo1 0.1314  ...   both colours survive
a red image and a blue image   IMG_...  0.0688  photo5 0.0665  photo2 0.0659  ...   nothing is both -> unconvinced
a red image not a cyan image   exiftest 0.1335  photo0 0.1324  photo1 0.0644  ...   cyan photo5 is gone
```

`photo5.jpg` (cyan) scores 0.0872 for the OR query and appears in the list; under
the `not a cyan image` clause it is rejected outright. AND fuses with `min`, so an
unsatisfiable pair collapses to ~0.07 against the ~0.13 a genuine match earns.

The checks assert the analyzer's own `combine`/`neg` fields, not just the
ranking -- a result that looks right for the wrong reason still fails. Both are
mutation-tested: injecting the cyan photo back, or flipping `combine=any` to
`all`, each exits non-zero with the specific field named.

### Metadata filters: date and GPS (offline gazetteer)

The vector queries above never touch the metadata path. These do: the offline
gazetteer resolves a place name to a coordinate, and the date parser produces a
range.

Fixture images carry GPS EXIF for three different cities. (`simctl addmedia`
*discards* `DateTimeOriginal` but **preserves GPS** -- verified, which is why the
date fixture relies on import batch rather than EXIF.)

```
evalplan|北京        |candidates=1|ocr=|clauses=0|combine=all|neg=0
evalplan|上海        |candidates=1|ocr=|clauses=0|combine=all|neg=0
evalplan|东京        |candidates=1|ocr=|clauses=0|combine=all|neg=0
evalplan|2026年9月14日|candidates=6|ocr=|clauses=0|combine=all|neg=0

北京         ok  gpstest.jpg  @ 39.9042,116.4072
上海         ok  shanghai.jpg @ 31.2304,121.4737
东京         ok  tokyo.jpg    @ 35.6762,139.6503
2026年9月14日 ok  6 results, all on 2026-09-14
```

Each city query narrows 23 assets to exactly the one photo taken there, so a
mis-resolved place name finds nothing rather than something plausible. Both checks
are mutation-tested:

| Mutation | Result |
|---|---|
| 北京 resolves to Tokyo's coordinates | `FAIL: 35.6762,139.6503 is 4.228,23.243 from the expected city` |
| A date-filtered result leaks a 2011 asset | `FAIL: tokyo.jpg is dated 2011-03-13, outside the requested range` |

Related, checked while building this: PhotoKit stores `-180,-180` in its own
database for assets with no fix. The index reads `PHAsset.location`, which is
`nil` for those, so they are excluded -- `with location: 8` on a 23-asset library
is exactly the 5 Apple stock photos that genuinely have coordinates plus the 3
fixtures. Had the sentinel been taken at face value, a query near the antimeridian
would have matched photos with no location at all.

### Similar-image search

Each seed's nearest neighbour is known from the fixture, and the seed must not
appear in its own results -- returning the query image as its own best match is
the classic way this feature looks broken while appearing to work.

```
photo0.jpg   -> exiftest.jpg (0.9725)   red's nearest neighbour is the other red
photo5.jpg   -> photo2.jpg   (0.9732)   cyan's nearest neighbour is blue
invoice.jpg  -> passport.jpg (0.7166)   a page of text resembles the other page of text
```

The scores order sensibly: two flat colours sit at ~0.97, while two rendered pages
-- which share layout and colour but differ in content -- sit at ~0.72.

Both failure modes are mutation-tested: injecting the seed as its own top hit
(`FAIL: the seed photo0.jpg returned itself`) and swapping in a wrong neighbour
(`FAIL: top is photo1.jpg, expected photo2.jpg`) each exit non-zero.

## The Metal kernel: an iOS-only bug the macOS gate could not see

**It is dead code by choice.** `MetalSimilaritySearch` / `EmbeddingSearchError` have
zero references outside their own file; the app searches via
`EmbeddingMatrixReader.scores(query:slots:)` -> Accelerate. `mode_metal` builds a
**macOS** harness, so its 31 green checks never covered iOS -- the same trap as the
conversion gates being green while the app held no model.

**It used to be wrong on iOS, and the root cause is alignment.** The app's
self-check runs the kernel in-process and compares against Accelerate using a
stored row as the query, so row 0 must self-match at ~1.0. Before the fix:

```
metal first: -1428.2224 0.0000 0.0090    <- outside the possible range
cpu first:     0.9999   0.9512 0.9360    <- correct
```

The measured cause:

```
page size:         16384    (getpagesize)
header page:        4096    (EmbeddingHeader.pageSize)
row start aligned: NO       base + 4096 is not a multiple of 16384
```

`makeBuffer(bytesNoCopy:)` requires a page-aligned pointer. The mmap base is
aligned but the rows begin one *header* page in, and 4096 is not a multiple of the
16384 hardware page -- so the GPU was handed a misaligned pointer and read the
wrong memory. macOS tolerates this; iOS does not. (An earlier hypothesis that
`(data as NSData).bytes` copies was tested and **ruled out**: same pointer.)

**Fix -- wrap the whole mapping and offset at bind time, keeping zero copy:**

```swift
let rowBuffer = device.makeBuffer(bytesNoCopy: base, length: mapped.count, ...)
encoder.setBuffer(rowBuffer, offset: EmbeddingHeader.pageSize, index: 0)
```

After the fix, on iOS:

```
metal top-10 == cpu: YES
max score delta:     1.39e-04     <- float16 storage precision
```

macOS stays green (31/31). A second latent issue was fixed at the same time: the
dispatch now clamps to `pipeline.maxTotalThreadsPerThreadgroup` instead of
assuming the preferred 256 is accepted everywhere.

**Why it is still not wired into search -- now measured, not deferred.**
`tools/models/metal_scale/main.swift` runs both paths over the same 100k x 768
matrix and the same query set:

```
accelerate: P50 9.16 ms, P95 9.41 ms, min 8.95 ms
metal:      P50 8.97 ms, P95 9.21 ms, min 5.74 ms
speedup:    1.02x
top-100 rankings agree: YES
max score delta:        6.56e-07
```

**1.02x is noise, not a win.** The scan is memory-bandwidth bound -- 192 MB read
per query -- so the GPU waits on the same bandwidth the CPU does and gains
nothing. Accelerate is already ~55x inside the 500 ms budget. Shipping the GPU
path would add a Metal dependency, a pipeline compilation and a second code path
to trust, in exchange for 2% on a metric nobody can perceive.

Run it with:

```sh
cd tools/models
xcrun -sdk macosx metal -c ../../PhotoVault/Search/EmbeddingSimilarity.metal -o /tmp/pv-embedding.air
xcrun -sdk macosx metallib /tmp/pv-embedding.air -o /tmp/pv-embedding.metallib
xcrun swiftc -O -o /tmp/pv-metal-scale metal_scale/main.swift \
  ../../PhotoVault/Search/EmbeddingStoreFile.swift \
  ../../PhotoVault/Search/MetalSimilaritySearch.swift -framework Metal
/tmp/pv-metal-scale --library /tmp/pv-embedding.metallib
```

The rankings agreeing at top-100 is the other half of the result: the fast path
and the reference path give the same answer, so "which one ships" is purely a
performance question -- and the answer is that it does not matter.
