#!/usr/bin/env python3
"""Dump fixtures that separate image *decoding* from image *resampling*.

The vision parity harness compares a Swift tensor against the tensor the Python
reference produced, and it was failing on JPEGs while PNGs matched to the last
bit. That is the signature of a decoder difference, not a resampling bug: Apple's
ImageIO and libjpeg implement the IDCT and chroma upsampling differently, so the
same JPEG yields slightly different pixels before any resizing happens.

That distinction matters because the two failures have different fixes. A
resampling bug is ours and must be fixed; a decoder difference is unavoidable,
because the app decodes with the platform decoder and the reference was built
with libjpeg. Conflating them makes it impossible to tell which is happening.

So this dumps, for each fixture:

  * ``raw_rgb.bin``       -- the exact RGB bytes PIL produced. Feeding these to
                             the Swift resampler removes decoding from the
                             comparison entirely: any remaining difference is
                             provably in the resampling.
  * ``expected.bin``      -- the tensor the reference preprocessing produced
                             from those same bytes.

Run:  python dump_resample_fixtures.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PARITY = HERE / "build" / "parity"
OUT = PARITY / "resample"

IMAGE_SIZE = 256
RESCALE = 0.00392156862745098
MEAN = 0.5
STD = 0.5


def main() -> int:
    manifest_path = PARITY / "manifest.json"
    if not manifest_path.exists():
        print(f"missing {manifest_path}; run: python verify_siglip2.py walk", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    image_paths = manifest["image_paths"]
    reference = np.fromfile(PARITY / "image_input.bin", dtype="<f4")
    per_image = 3 * IMAGE_SIZE * IMAGE_SIZE

    try:
        from PIL import Image
    except ImportError:
        print("Pillow is required", file=sys.stderr)
        return 1

    OUT.mkdir(parents=True, exist_ok=True)

    raw_chunks: list[bytes] = []
    expected_chunks: list[np.ndarray] = []
    records: list[dict] = []
    offset = 0

    # A second copy of the reference tensor, recomputed here from PIL directly.
    # If this disagrees with `image_input.bin`, this script is not faithfully
    # reproducing the reference preprocessing and its fixtures would be
    # misleading -- so it is checked rather than assumed.
    worst_self_check = 0.0

    for index, relative in enumerate(image_paths):
        path = PARITY / relative
        if not path.exists():
            continue
        with Image.open(path) as handle:
            rgb = handle.convert("RGB")
            width, height = rgb.size
            raw = rgb.tobytes()
            # The manifest's order is resize -> rescale -> normalize, and the
            # resize squashes to a square without preserving aspect ratio.
            resized = rgb.resize((IMAGE_SIZE, IMAGE_SIZE), Image.BILINEAR)

        array = np.asarray(resized, dtype=np.float32)
        tensor = (array * RESCALE - MEAN) / STD          # HWC, float32
        tensor = np.transpose(tensor, (2, 0, 1))          # CHW
        tensor = tensor[None, ...]                        # NCHW

        expected_flat = tensor.reshape(-1)
        raw_reference = reference[index * per_image:(index + 1) * per_image]
        if raw_reference.size == expected_flat.size:
            worst_self_check = max(
                worst_self_check,
                float(np.abs(expected_flat - raw_reference).max()),
            )

        raw_chunks.append(raw)
        expected_chunks.append(expected_flat.astype("<f4"))
        records.append({
            "name": Path(relative).name,
            "width": width,
            "height": height,
            "rawOffset": offset,
            "rawLength": len(raw),
        })
        offset += len(raw)
        print(f"  {Path(relative).name}: {width}x{height}")

    if not records:
        print("no fixture images found", file=sys.stderr)
        return 1

    (OUT / "raw_rgb.bin").write_bytes(b"".join(raw_chunks))
    np.concatenate(expected_chunks).tofile(OUT / "expected.bin")
    (OUT / "manifest.json").write_text(json.dumps({
        "imageSize": IMAGE_SIZE,
        "images": records,
        "provenance": (
            "raw_rgb.bin is PIL's convert('RGB') output; expected.bin is the "
            "reference preprocessing applied to exactly those bytes."
        ),
    }, indent=2))

    print(f"\n{len(records)} fixtures -> {OUT}")
    print(f"self-check against image_input.bin: max abs difference {worst_self_check:.6f}")
    if worst_self_check > 0.002:
        print("WARNING: this script does not reproduce the reference preprocessing;")
        print("         the isolated fixtures below would be misleading.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
