#!/usr/bin/env python3
"""Generate the labelled image fixture that `eval_retrieval.py` scores against.

Deterministic: same seed, same bytes, so the fixture and its labels cannot drift
apart. Colours are rendered as flat fields because a flat field has an
unambiguous ground truth -- "a red image" is not a judgement call the way
labelling a photograph would be.

The rendered words exist to exercise the *other* retrieval pathway: `invoice` and
`passport` are found through Vision OCR text rather than through appearance, so a
ranking that puts them first proves OCR output really reaches the search engine.

    python3 tools/models/make_eval_fixture.py --output /tmp/evalset
    xcrun simctl addmedia <simulator-udid> /tmp/evalset/*.jpg

Then launch the app with `--pv-ai-selfcheck --pv-ai-selfcheck-index` and score the
resulting log with `eval_retrieval.py`.

Note: `simctl addmedia` assigns its own creation date (verified -- EXIF
DateTimeOriginal is discarded) and *reorders* the batch, so neither the import
order nor the Photos database's `ZFILENAME` can serve as the label. The asset's
original filename survives, which is why the fixture is keyed by filename.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

COLOURS = {
    "photo0.jpg": (220, 60, 60),    # red
    "photo1.jpg": (60, 180, 90),    # green
    "photo2.jpg": (70, 110, 231),   # blue
    "photo3.jpg": (230, 190, 59),   # yellow
    "photo4.jpg": (150, 81, 200),   # purple
    "photo5.jpg": (39, 190, 199),   # cyan
    "exiftest.jpg": (254, 0, 0),    # a second red, to give recall@k something to find
}

WORDS = ["invoice", "passport"]

SIZE = (1000, 400)
FONT_PATH = "/System/Library/Fonts/Helvetica.ttc"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", type=Path, default=Path("/tmp/evalset"))
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    for name, rgb in COLOURS.items():
        path = args.output / name
        Image.new("RGB", (640, 480), rgb).save(path, quality=95)
        print(f"{path}  flat rgb{rgb}")

    try:
        font = ImageFont.truetype(FONT_PATH, 150)
    except OSError:
        font = ImageFont.load_default()

    for word in WORDS:
        path = args.output / f"{word}.jpg"
        image = Image.new("RGB", SIZE, (255, 255, 255))
        draw = ImageDraw.Draw(image)
        box = draw.textbbox((0, 0), word.upper(), font=font)
        draw.text(
            ((SIZE[0] - (box[2] - box[0])) / 2, (SIZE[1] - (box[3] - box[1])) / 2 - box[1]),
            word.upper(),
            fill=(0, 0, 0),
            font=font,
        )
        image.save(path, quality=95)
        print(f"{path}  rendered text {word.upper()!r}")

    print(f"\n{len(COLOURS) + len(WORDS)} images in {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
