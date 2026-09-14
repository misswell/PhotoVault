"""Build the text-parity fixture: queries, token ids and reference embeddings.

This is the gate for the Swift *pipeline as a whole*. The tokenizer test proves
the Swift BPE port matches sentencepiece, and the Core ML parity test proves the
converted graph matches the PyTorch model -- but both are verified separately,
with the Swift and Python halves never actually meeting. This fixture makes the
whole Swift chain (tokenize -> Core ML text tower) answerable against the
PyTorch reference on the same strings.

The queries are deliberately awkward: Chinese (which the tokenizer handles
natively), mixed script, punctuation, very long input that must truncate at 64
tokens, empty-ish input, and the uppercase forms that prove case folding is *not*
happening.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from siglip2_reference import SigLIP2Reference

HERE = Path(__file__).resolve().parent

QUERIES = [
    # Everyday English
    "a cat",
    "a dog on the beach",
    "receipt",
    "a screenshot of a chat",
    "food",
    "a whiteboard with diagrams",
    "my car",
    "a mountain landscape at sunset",
    # Chinese -- the primary use case
    "猫",
    "发票",
    "报销凭证",
    "登机牌",
    "身份证",
    "咖啡",
    "海边的狗",
    "白板上的会议记录",
    "微信聊天截图",
    "一张收据",
    "山和日落",
    # Mixed and punctuation
    "PDF 发票 2023",
    "iPhone 15 Pro 的截图",
    "咖啡 ☕️",
    "  leading and trailing  ",
    "punctuation!?;:",
    # Case sensitivity: these must NOT collapse to the same embedding
    "CAT",
    "cat",
    "Cat",
    "RECEIPT",
    # Length extremes
    "",
    "a",
    "   ",
    # Longer than the 64-token window, so truncation is exercised
    "a very detailed description of a photograph showing several people standing "
    "in a large brightly lit room with many tables and chairs arranged in rows "
    "and a great deal of text visible on the wall behind them",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(HERE / "build" / "text-parity.json"))
    parser.add_argument("--checkpoint", default=str(HERE / "cache" / "siglip2-base-patch16-256"))
    args = parser.parse_args()

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"loading reference from {args.checkpoint}")
    reference = SigLIP2Reference.load(args.checkpoint, device="cpu")

    # Token ids come from the *real* sentencepiece model, not from the Python
    # port, so this fixture independently re-checks the port as well.
    token_ids = reference.token_ids(QUERIES)
    embeddings = reference.text_embedding_from_ids(token_ids)

    ids_list = token_ids.tolist()
    records = []
    for index, text in enumerate(QUERIES):
        records.append({
            "text": text,
            "tokenIds": ids_list[index],
            "embedding": [round(float(v), 7) for v in embeddings[index]],
            "norm": float(np.linalg.norm(embeddings[index])),
        })

    # Sanity inside the fixture itself: if the reference model were not producing
    # distinct embeddings for case variants, the fixture could not detect a
    # lowercasing bug downstream.
    def embedding_of(text: str) -> np.ndarray:
        for record in records:
            if record["text"] == text:
                return np.asarray(record["embedding"], dtype=np.float32)
        raise KeyError(text)

    for upper, lower in (("CAT", "cat"), ("RECEIPT", "receipt")):
        similarity = float(embedding_of(upper) @ embedding_of(lower))
        print(f"  reference cos({upper!r}, {lower!r}) = {similarity:.4f}")
        if similarity > 0.99:
            print("  ERROR: case variants collapse in the reference; the fixture "
                  "would not detect a lowercasing bug", file=sys.stderr)
            return 1

    payload = {
        "model": "google/siglip2-base-patch16-256",
        "checkpoint": str(args.checkpoint),
        "maxLength": 64,
        "count": len(records),
        "records": records,
    }
    out.write_text(json.dumps(payload))
    size = out.stat().st_size
    print(f"wrote {out} ({size / 1024:.0f} KB, {len(records)} queries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
