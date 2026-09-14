"""SigLIP2 tokenizer — a faithful, dependency-free reimplementation.

Why this exists
---------------
The app must tokenize Chinese and English queries on device, in Swift, with
output **identical** to the Python reference. The two obvious routes are both
bad: shipping `sentencepiece` means vendoring a large C++ library and building
it for iOS, and shipping `tokenizer.json` means parsing 34 MB of JSON at launch.

So this module is the *executable specification*: a direct port of
`src/bpe_model.cc` (Apache-2.0) from google/sentencepiece @ v0.2.0, specialised
to the exact configuration this checkpoint was trained with. `verify_siglip2.py
--mode tokenizer` proves it agrees with the real sentencepiece processor, and
the Swift port is validated against *this* module's ground-truth dump.

The configuration, read from `tokenizer.model` rather than assumed
---------------------------------------------------------------
| field                     | value    | consequence                         |
|---------------------------|----------|-------------------------------------|
| `model_type`              | 2 (BPE)  | merge-by-score, not unigram Viterbi |
| `precompiled_charsmap`    | **empty**| no NFKC, no case folding at all     |
| `name`                    | identity | normalization is a no-op            |
| `add_dummy_prefix`        | **False**| no leading `▁` is inserted          |
| `remove_extra_whitespaces`| False    | runs of spaces are preserved        |
| `escape_whitespaces`      | True     | `' '` -> `U+2581`                   |
| `byte_fallback`           | True     | unknown text becomes `<0xXX>`       |

The empty `precompiled_charsmap` is the single most important fact here: it
means the normalizer needs no double-array trie, which is the piece that would
otherwise make a Swift port genuinely painful.

Two subtleties that a from-scratch implementation gets wrong
------------------------------------------------------------
1. **The initial split is not "one character each."** `ModelInterface`
   builds its `PrefixMatcher` from the **USER_DEFINED** pieces only (245 of
   them here: `<start_of_turn>`, `\\n\\n`, `▁▁`, HTML tags, ...). One character
   is the *fallback* when that trie has no match. Symbols matched this way are
   `freeze`d and never merge.
2. **Merging is by piece score, not by training order.** At each step the best
   adjacent pair is merged, ties broken by leftmost. This is *not* classic
   rank-based BPE, and it is why naively re-deriving merges from scores in a
   different order gives different tokens.

Escaping note: this docstring is a Python string, so `\\n` above is the
two-character sequence backslash-n as written; the actual pieces are real
newlines.
"""

from __future__ import annotations

import argparse
import heapq
import json
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

SPIECE_UNDERLINE = "\u2581"

# Enum values as they appear in this checkpoint's ModelProto. Note the numbering
# is 1-based and does *not* match the conventional sentencepiece enum order that
# most ports assume (the pb2 ships NORMAL=1, UNKNOWN=2, CONTROL=3,
# USER_DEFINED=4, UNUSED=5, BYTE=6).
TYPE_NORMAL = 1
TYPE_UNKNOWN = 2
TYPE_CONTROL = 3
TYPE_USER_DEFINED = 4
TYPE_UNUSED = 5
TYPE_BYTE = 6


def _one_char_len(text: str, i: int) -> int:
    """Length of one character, matching `string_util::OneCharLen`.

    Python str indices are already per-code-point, so one character is 1.
    """
    return 1


@dataclass
class TokenizerFacts:
    vocab_size: int
    unk_id: int
    bos_id: int
    eos_id: int
    pad_id: int
    model_type: int
    byte_fallback: bool
    add_dummy_prefix: bool
    remove_extra_whitespaces: bool
    escape_whitespaces: bool
    normalization_rule_name: str
    precompiled_charsmap_bytes: int
    user_defined_count: int
    unused_count: int
    byte_piece_count: int


class SigLIP2Tokenizer:
    """BPE tokenizer matching `GemmaTokenizer` + this checkpoint's spm model."""

    def __init__(self, model_path: str | Path):
        self.model_path = Path(model_path)
        if not self.model_path.exists():
            raise FileNotFoundError(f"tokenizer model not found: {self.model_path}")
        self._parse_proto(self.model_path.read_bytes())
        self._build_index()

    # ---------------------------------------------------------------- parsing

    def _parse_proto(self, blob: bytes) -> None:
        """Minimal ModelProto reader.

        Only the fields this tokenizer needs: repeated `pieces` (each a
        SentencePiece with `piece`, `score`, `type`), the normalizer spec, the
        trainer spec's special ids, and `byte_fallback`.

        Hand-rolled rather than using the generated pb2 so the *Swift* side can
        mirror it field for field; see `to_binary_artifact` for the on-device
        format, which is this same information in a load-friendly layout.
        """
        pieces: list[tuple[str, float, int]] = []
        self._byte_fallback = False
        self._model_type = 0
        self._sp_unk_id = 0
        self._sp_bos_id = 0
        self._sp_eos_id = 0
        self._sp_pad_id = 0
        self._norm_name = ""
        self._charsmap_len = 0
        # proto2 declared defaults for NormalizerSpec. A field set to its default
        # is omitted from the wire, so absent means "true" for these three --
        # assuming False silently disables whitespace escaping.
        self._add_dummy_prefix = True
        self._remove_extra_whitespaces = True
        self._escape_whitespaces = True

        for field, wire, value in _iter_fields(blob):
            if field == 1 and wire == 2:  # repeated SentencePiece pieces
                pieces.append(self._parse_piece(value))
            elif field == 2 and wire == 2:  # trainer_spec
                self._parse_trainer_spec(value)
            elif field == 3 and wire == 2:  # normalizer_spec
                self._parse_normalizer_spec(value)

        if not pieces:
            raise ValueError("no pieces parsed from tokenizer.model")
        self._pieces = pieces

    def _parse_trainer_spec(self, blob: bytes) -> None:
        """Field numbers are the real TrainerSpec ones (verified, not guessed):

        3 = model_type, 35 = byte_fallback, 40..43 = unk/bos/eos/pad id.
        Getting these wrong is silent: you get a tokenizer that emits plausible
        ids with the wrong special tokens.
        """
        for field, wire, value in _iter_fields(blob):
            if wire != 0:
                continue
            if field == 3:
                self._model_type = value
            elif field == 35:
                self._byte_fallback = bool(value)
            elif field == 40:
                self._sp_unk_id = value
            elif field == 41:
                self._sp_bos_id = value
            elif field == 42:
                self._sp_eos_id = value
            elif field == 43:
                self._sp_pad_id = value

    def _parse_normalizer_spec(self, blob: bytes) -> None:
        for field, wire, value in _iter_fields(blob):
            if field == 1 and wire == 2:
                self._norm_name = value.decode("utf-8", "replace")
            elif field == 2 and wire == 2:
                self._charsmap_len = len(value)
            elif field == 3 and wire == 0:
                self._add_dummy_prefix = bool(value)
            elif field == 4 and wire == 0:
                self._remove_extra_whitespaces = bool(value)
            elif field == 5 and wire == 0:
                self._escape_whitespaces = bool(value)

    @staticmethod
    def _parse_piece(blob: bytes) -> tuple[str, float, int]:
        piece, score, ptype = "", 0.0, TYPE_NORMAL
        for field, wire, value in _iter_fields(blob):
            if field == 1 and wire == 2:
                piece = value.decode("utf-8", "surrogateescape")
            elif field == 2 and wire == 5:
                score = struct.unpack("<f", value)[0]
            elif field == 3 and wire == 0:
                ptype = value
        return piece, score, ptype

    # ---------------------------------------------------------------- indexing

    def _build_index(self) -> None:
        self._vocab: dict[str, int] = {}
        self._scores: list[float] = []
        self._types: list[int] = []
        user_defined: list[str] = []
        byte_pieces: dict[int, int] = {}
        unused = user_defined_named = 0
        control_unknown: list[int] = []

        for i, (piece, score, ptype) in enumerate(self._pieces):
            self._vocab.setdefault(piece, i)
            self._scores.append(score)
            self._types.append(ptype)
            if ptype == TYPE_USER_DEFINED:
                user_defined.append(piece)
                user_defined_named += 1
            elif ptype == TYPE_UNUSED:
                unused += 1
            elif ptype == TYPE_BYTE:
                # `<0xAB>` -> 0xAB
                try:
                    byte_pieces[int(piece[3:5], 16)] = i
                except ValueError:
                    pass
            if ptype in (TYPE_CONTROL, TYPE_UNKNOWN):
                control_unknown.append(i)

        # `ModelInterface::InitializePieces` builds the prefix matcher from the
        # USER_DEFINED set only. Getting this wrong changes the initial split.
        self._user_defined = user_defined
        self._ud_by_first: dict[str, list[str]] = {}
        for piece in user_defined:
            if piece:
                self._ud_by_first.setdefault(piece[0], []).append(piece)
        self._byte_pieces = byte_pieces

        self.unk_id = self._sp_unk_id
        self.bos_id = self._sp_bos_id
        self.eos_id = self._sp_eos_id
        self.pad_id = self._sp_pad_id
        if self.unk_id == 0 and 3 in control_unknown:
            self.unk_id = 3

        self.facts = TokenizerFacts(
            vocab_size=len(self._pieces),
            unk_id=self.unk_id,
            bos_id=self.bos_id,
            eos_id=self.eos_id,
            pad_id=self.pad_id,
            model_type=self._model_type,
            byte_fallback=self._byte_fallback,
            add_dummy_prefix=self._add_dummy_prefix,
            remove_extra_whitespaces=self._remove_extra_whitespaces,
            escape_whitespaces=self._escape_whitespaces,
            normalization_rule_name=self._norm_name,
            precompiled_charsmap_bytes=self._charsmap_len,
            user_defined_count=user_defined_named,
            unused_count=unused,
            byte_piece_count=len(byte_pieces),
        )

    # -------------------------------------------------------------- algorithm

    def normalize(self, text: str) -> str:
        """The whole normalizer, for this checkpoint.

        `name == "identity"` and `precompiled_charsmap` is empty, so there is no
        NFKC and no case folding. `add_dummy_prefix` is False, so no leading
        `▁`. Only whitespace escaping applies.
        """
        if self._escape_whitespaces:
            text = text.replace(" ", SPIECE_UNDERLINE)
        if self._add_dummy_prefix:
            text = SPIECE_UNDERLINE + text
        if self._remove_extra_whitespaces:
            out = []
            prev_space = False
            for ch in text:
                is_space = ch == SPIECE_UNDERLINE
                if is_space and prev_space:
                    continue
                out.append(ch)
                prev_space = is_space
            text = "".join(out)
        return text

    def _prefix_match(self, text: str, i: int) -> tuple[int, bool]:
        """Port of `PrefixMatcher::PrefixMatch`.

        Returns (length, found). `found` is True iff the longest match came from
        the user-defined trie; that symbol is then frozen and never merged.
        """
        candidates = self._ud_by_first.get(text[i]) if i < len(text) else None
        if not candidates:
            return _one_char_len(text, i), False
        best = 0
        for piece in candidates:
            if len(piece) > best and text.startswith(piece, i):
                best = len(piece)
        if best == 0:
            return _one_char_len(text, i), False
        return best, True

    def encode(self, text: str, add_eos: bool = True, max_length: int | None = 64) -> list[int]:
        """Tokens for `text`, EOS-terminated and optionally right-padded.

        Mirrors `SentencePieceProcessor::Encode` (byte fallback included)
        followed by `GemmaTokenizer.build_inputs_with_special_tokens`, which
        appends EOS because the checkpoint sets `add_eos_token`. Padding uses
        `<pad>` = 0, matching `padding="max_length"`.
        """
        normalized = self.normalize(text)
        pieces = self._bpe(normalized)
        ids: list[int] = []
        for piece in pieces:
            tid = self._vocab.get(piece)
            if tid is None or tid == self.unk_id:
                if self._byte_fallback:
                    for b in piece.encode("utf-8", "surrogateescape"):
                        ids.append(self._byte_pieces.get(b, self.unk_id))
                else:
                    ids.append(self.unk_id)
            else:
                ids.append(tid)

        if add_eos:
            ids.append(self.eos_id)
        if max_length is not None:
            if len(ids) > max_length:
                ids = ids[:max_length]
            else:
                ids = ids + [self.pad_id] * (max_length - len(ids))
        return ids

    def _bpe(self, normalized: str) -> list[str]:
        """Port of `bpe::Model::SampleEncode` with alpha=0 (no dropout)."""
        if not normalized:
            return []

        # Symbols are (piece, prev, next, frozen); `piece == ""` means deleted.
        pieces: list[str] = []
        prev: list[int] = []
        nxt: list[int] = []
        frozen: list[bool] = []

        i = 0
        while i < len(normalized):
            mblen, found = self._prefix_match(normalized, i)
            pieces.append(normalized[i : i + mblen])
            prev.append(len(pieces) - 2)
            nxt.append(len(pieces))  # fixed up below
            frozen.append(found)
            i += mblen
        for k in range(len(pieces) - 1):
            nxt[k] = k + 1
        nxt[-1] = -1

        # Max-heap on score, ties broken by smaller left index. Python's heap is
        # a min-heap, so the score is negated; `left` is pushed as-is because
        # ties must prefer the *smaller* left, which the min-heap already does.
        heap: list[tuple[float, int, int, int]] = []

        def maybe_add(left: int, right: int) -> None:
            if left == -1 or right == -1 or frozen[left] or frozen[right]:
                return
            merged = pieces[left] + pieces[right]
            tid = self._vocab.get(merged)
            if tid is None:
                return
            # (negated score, left, right, byte length of the merged piece)
            heapq.heappush(heap, (-self._scores[tid], left, right, len(merged)))

        for k in range(1, len(pieces)):
            maybe_add(k - 1, k)

        while heap:
            _neg, left, right, size = heapq.heappop(heap)
            if not pieces[left] or not pieces[right]:
                continue
            if len(pieces[left]) + len(pieces[right]) != size:
                # Stale: one side grew or was absorbed since this pair was
                # queued. Pieces only ever get longer, so equal length means
                # both are unchanged and still adjacent.
                continue
            pieces[left] = pieces[left] + pieces[right]
            nxt[left] = nxt[right]
            if nxt[right] != -1:
                prev[nxt[right]] = left
            pieces[right] = ""
            maybe_add(prev[left], left)
            maybe_add(left, nxt[left])

        out: list[str] = []
        index = 0 if pieces else -1
        while index != -1:
            if pieces[index]:
                out.append(pieces[index])
            index = nxt[index]

        # `resegment` only matters for UNUSED pieces; this vocab has none, so
        # the output is already final. Assert rather than silently diverge.
        for piece in out:
            tid = self._vocab.get(piece)
            if tid is not None and self._types[tid] == TYPE_UNUSED:
                raise NotImplementedError(
                    "model contains UNUSED pieces; resegmentation is required "
                    "and is deliberately not implemented for this checkpoint"
                )
        return out

    # ------------------------------------------------------------- artifacts

    def to_binary_artifact(self, out_path: str | Path, source_sha256: str = "") -> dict:
        """Write the compact on-device tokenizer.

        Layout (little-endian, all offsets absolute):

            magic    8s   "PVTOK002"
            u32      flags            bit0 byte_fallback, bit1 escape_ws,
                                      bit2 add_dummy_prefix, bit3 remove_extra_ws
            u32      vocab_size
            i32      unk_id, bos_id, eos_id, pad_id
            u32      user_defined_count
            u32      blob_offset      start of the string blob
            u32      blob_length
            u32      piece_offset     vocab_size u32 offsets into the blob
            u32      score_offset     vocab_size f32
            u32      type_offset      vocab_size u8
            u32      ud_offset        user_defined_count u32 piece ids
            u32      byte_offset      256 u32: byte value -> piece id
            u32      sorted_offset    vocab_size u32 piece ids, sorted by the
                                      piece's UTF-8 bytes (lexicographic)
            u32      source_sha_len, then bytes (provenance)

        The pieces themselves are stored end-to-end in the blob, so the whole
        file is one allocation plus a few index arrays — no per-piece Swift
        String is needed until a piece actually wins a merge.

        `sorted_ids` is what makes the Swift side cheap. Steps number in the
        tens for a search query, and each step asks "is this concatenation a
        piece?". With a lexicographically sorted id list that question is a
        binary search over the blob (~18 memcmp of a few bytes), so the app
        never builds a 256000-entry dictionary and never materialises 256000
        Strings at launch. On a 256k vocabulary that is the difference between
        a few hundred KB of resident bytes and tens of MB.
        """
        out_path = Path(out_path)
        blob = bytearray()
        offsets: list[int] = []
        scores = bytearray()
        types = bytearray()
        for piece, score, ptype in self._pieces:
            raw = piece.encode("utf-8", "surrogateescape")
            offsets.append(len(blob))
            blob += raw
            scores += struct.pack("<f", score)
            types.append(ptype & 0xFF)
        offsets.append(len(blob))

        user_defined_ids: list[int] = []
        for i, (_p, _s, ptype) in enumerate(self._pieces):
            if ptype == TYPE_USER_DEFINED and self._pieces[i][0]:
                user_defined_ids.append(i)

        byte_ids = [self.unk_id] * 256
        for b, pid in self._byte_pieces.items():
            byte_ids[b] = pid

        # Sort ids by the piece's UTF-8 bytes. Python's bytes comparison is
        # lexicographic on the encoded form, which is exactly what Swift's
        # binary search will reproduce.
        sorted_ids = sorted(
            range(len(self._pieces)),
            key=lambda i: self._pieces[i][0].encode("utf-8", "surrogateescape"),
        )

        flags = 0
        if self._byte_fallback:
            flags |= 1
        if self._escape_whitespaces:
            flags |= 2
        if self._add_dummy_prefix:
            flags |= 4
        if self._remove_extra_whitespaces:
            flags |= 8

        # Fixed header: 8 magic + 4 flags + 4 vocab_size + 4*4 special ids
        # + 4 ud_count + 10 u32 offsets/lengths (piece_table, blob_offset,
        # blob_length, score_offset, type_offset, ud_offset, byte_offset,
        # sorted_offset, sha_offset, sha_len) = 76 bytes.
        header_size = 8 + 4 + 4 + 4 * 4 + 4 + 10 * 4
        piece_table = header_size
        blob_offset = piece_table + 4 * (len(offsets))
        score_offset = blob_offset + len(blob)
        type_offset = score_offset + len(scores)
        ud_offset = type_offset + len(types)
        byte_offset = ud_offset + 4 * len(user_defined_ids)
        sorted_offset = byte_offset + 4 * 256
        sha_offset = sorted_offset + 4 * len(sorted_ids)
        sha = source_sha256.encode("utf-8")

        buf = bytearray()
        buf += b"PVTOK002"
        buf += struct.pack("<I", flags)
        buf += struct.pack("<I", len(self._pieces))
        buf += struct.pack("<4i", self.unk_id, self.bos_id, self.eos_id, self.pad_id)
        buf += struct.pack("<I", len(user_defined_ids))
        buf += struct.pack("<I", piece_table)
        buf += struct.pack("<I", blob_offset)
        buf += struct.pack("<I", len(blob))
        buf += struct.pack("<I", score_offset)
        buf += struct.pack("<I", type_offset)
        buf += struct.pack("<I", ud_offset)
        buf += struct.pack("<I", byte_offset)
        buf += struct.pack("<I", sorted_offset)
        buf += struct.pack("<I", sha_offset)
        buf += struct.pack("<I", len(sha))
        assert len(buf) == header_size, (len(buf), header_size)
        buf += struct.pack(f"<{len(offsets)}I", *offsets)
        buf += blob
        buf += scores
        buf += types
        buf += struct.pack(f"<{len(user_defined_ids)}I", *user_defined_ids)
        buf += struct.pack("<256I", *byte_ids)
        buf += struct.pack(f"<{len(sorted_ids)}I", *sorted_ids)
        buf += sha
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(bytes(buf))

        return {
            "path": str(out_path),
            "bytes": len(buf),
            "vocabSize": len(self._pieces),
            "blobBytes": len(blob),
            "userDefinedCount": len(user_defined_ids),
            "sortedIndexCount": len(sorted_ids),
            "sourceSha256": source_sha256,
        }

    # ----------------------------------------------------------------- checks

    def describe(self) -> dict:
        f = self.facts
        return {
            "vocabSize": f.vocab_size,
            "modelType": "BPE" if f.model_type == 2 else f"other({f.model_type})",
            "byteFallback": f.byte_fallback,
            "normalization": f.normalization_rule_name,
            "precompiledCharsmapBytes": f.precompiled_charsmap_bytes,
            "addDummyPrefix": f.add_dummy_prefix,
            "removeExtraWhitespaces": f.remove_extra_whitespaces,
            "escapeWhitespaces": f.escape_whitespaces,
            "specialIds": {"unk": f.unk_id, "bos": f.bos_id, "eos": f.eos_id, "pad": f.pad_id},
            "userDefinedPieces": f.user_defined_count,
            "unusedPieces": f.unused_count,
            "bytePieces": f.byte_piece_count,
        }


def _iter_fields(blob: bytes):
    """Yield (field_number, wire_type, value) from a protobuf message."""
    i = 0
    n = len(blob)
    while i < n:
        key, i = _read_varint(blob, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, i = _read_varint(blob, i)
        elif wire == 1:
            value = blob[i : i + 8]
            i += 8
        elif wire == 2:
            length, i = _read_varint(blob, i)
            value = blob[i : i + length]
            i += length
        elif wire == 5:
            value = blob[i : i + 4]
            i += 4
        else:
            raise ValueError(f"unsupported protobuf wire type {wire} at {i}")
        yield field, wire, value


def _read_varint(blob: bytes, i: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        b = blob[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def _sha256(path: Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="SigLIP2 tokenizer (Swift-portable spec)")
    ap.add_argument("--model", default="cache/siglip2-base-patch16-256/tokenizer.model")
    ap.add_argument("--describe", action="store_true", help="print configuration facts")
    ap.add_argument("--encode", nargs="*", help="encode these strings and print ids")
    ap.add_argument("--artifact", help="write the compact on-device tokenizer")
    ap.add_argument("--corpus", help="JSON file with a list of strings to tokenize")
    ap.add_argument("--ground-truth", help="write corpus token ids as JSON for the Swift test")
    ap.add_argument("--compare-sentencepiece", action="store_true", default=None,
                    help="with --corpus, diff against the real sentencepiece processor")
    args = ap.parse_args()

    tok = SigLIP2Tokenizer(args.model)

    if args.describe or not any([args.encode, args.artifact, args.corpus]):
        print(json.dumps(tok.describe(), indent=2, ensure_ascii=False))

    if args.encode:
        for text in args.encode:
            print(f"{text!r} -> {tok.encode(text, max_length=None)}")

    if args.artifact:
        info = tok.to_binary_artifact(args.artifact, _sha256(tok.model_path))
        print(json.dumps(info, indent=2))

    if args.corpus:
        corpus = json.loads(Path(args.corpus).read_text())
        texts = corpus["texts"] if isinstance(corpus, dict) else corpus
        ids = [tok.encode(t, max_length=64) for t in texts]
        if args.ground_truth:
            Path(args.ground_truth).write_text(
                json.dumps({"texts": texts, "ids": ids}, ensure_ascii=False)
            )
            print(f"wrote {len(ids)} token sequences to {args.ground_truth}")

        if args.compare_sentencepiece:
            import sentencepiece as spm

            sp = spm.SentencePieceProcessor(model_file=str(tok.model_path))
            bad = 0
            for text, got in zip(texts, ids):
                want = sp.encode(text) + [tok.eos_id]
                want = want[:64] + [tok.pad_id] * max(0, 64 - len(want))
                if got != want:
                    bad += 1
                    if bad <= 10:
                        print(f"MISMATCH {text!r}\n  ours: {got}\n  spm : {want}")
            print(f"corpus {len(texts)} strings, {bad} mismatches vs sentencepiece")
            return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
