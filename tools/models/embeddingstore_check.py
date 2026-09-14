"""Independent verification of the embedding matrix and its search results.

Reads the `PVEMB001` file that the Swift code wrote and recomputes the top-k
with NumPy, without sharing any code with the Swift implementation. If the file
layout, the Float16 interpretation, or the normalization convention were wrong
in a way Swift's own tests cannot see (because they would share the mistake),
this disagrees.

Also serves as the golden reference for the Phase 4 Metal kernel: the kernel must
reproduce these rankings, not merely "look reasonable".
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np

MAGIC = b"PVEMB001"
PAGE_SIZE = 4096


def read_header(path: Path) -> dict:
    with path.open("rb") as handle:
        header = handle.read(PAGE_SIZE)
    if len(header) < PAGE_SIZE:
        raise SystemExit(f"{path} is shorter than one header page")
    if header[:8] != MAGIC:
        raise SystemExit(f"bad magic: {header[:8]!r}")
    (version,) = struct.unpack_from("<I", header, 8)
    (dimension,) = struct.unpack_from("<I", header, 12)
    (count,) = struct.unpack_from("<Q", header, 16)
    (capacity,) = struct.unpack_from("<Q", header, 24)
    source_hash = header[40:104].split(b"\x00", 1)[0].decode()
    (generation,) = struct.unpack_from("<Q", header, 104)
    (checksum,) = struct.unpack_from("<Q", header, 120)

    # Same FNV-1a over the same range, with the checksum field zeroed.
    probe = bytearray(header[:PAGE_SIZE])
    probe[120:128] = b"\x00" * 8
    recomputed = fnv1a(bytes(probe[:120]))
    return {
        "version": version,
        "dimension": dimension,
        "count": count,
        "capacity": capacity,
        "sourceHash": source_hash,
        "generation": generation,
        "checksum": checksum,
        "checksumMatches": recomputed == checksum,
    }


def fnv1a(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def load_matrix(path: Path, dimension: int, count: int) -> np.ndarray:
    """Memory-mapped Float16 matrix, `count` rows of `dimension`."""
    expected = PAGE_SIZE + count * dimension * 2
    actual = path.stat().st_size
    if actual < expected:
        raise SystemExit(f"matrix is truncated: {actual} bytes, expected at least {expected}")
    return np.memmap(
        path, dtype="<f2", mode="r", offset=PAGE_SIZE, shape=(count, dimension)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", default="build/embedding-bench-results.json")
    parser.add_argument("--matrix", help="override the matrix path from the results file")
    parser.add_argument("--tolerance", type=float, default=2e-3,
                        help="allowed absolute difference in similarity")
    args = parser.parse_args()

    results_path = Path(args.results)
    if not results_path.exists():
        raise SystemExit(f"no results at {results_path}; run the Swift benchmark first")
    payload = json.loads(results_path.read_text())

    matrix_path = Path(args.matrix or payload["matrixPath"])
    header = read_header(matrix_path)
    print(f"matrix {matrix_path}")
    print(f"  version {header['version']}, dimension {header['dimension']}, "
          f"count {header['count']}, capacity {header['capacity']}")
    print(f"  source hash {header['sourceHash'][:16]}…, generation {header['generation']}")
    print(f"  header checksum verified in Python: {header['checksumMatches']}")

    problems = 0
    if not header["checksumMatches"]:
        print("  FAIL: Python's FNV-1a disagrees with the stored checksum")
        problems += 1
    if header["dimension"] != payload["dimension"]:
        print("  FAIL: dimension disagrees with the Swift results")
        problems += 1
    if header["count"] != payload["rowCount"]:
        print(f"  FAIL: count {header['count']} != {payload['rowCount']}")
        problems += 1

    matrix = load_matrix(matrix_path, header["dimension"], header["count"])
    dim = header["dimension"]

    # The invariant the Swift fast path assumes. Checking it here means a wrong
    # assumption shows up as a failure rather than as subtly wrong rankings.
    norms = np.linalg.norm(matrix.astype(np.float32), axis=1)
    print(f"  row norms: min {norms.min():.6f}, max {norms.max():.6f}, "
          f"max deviation from 1: {np.abs(norms - 1).max():.6f}")
    if np.abs(norms - 1).max() > 0.01:
        print("  FAIL: rows are not unit length")
        problems += 1

    for index, (query, swiftTop) in enumerate(zip(payload["queries"], payload["results"])):
        q = np.asarray(query, dtype=np.float32)
        q = q / np.linalg.norm(q)
        # Dot against the normalized query. Rows are unit length, so this is cosine.
        scores = matrix.astype(np.float32) @ q
        order = np.lexsort((np.arange(len(scores)), -scores))[: payload["topK"]]

        swift_slots = [entry["slot"] for entry in swiftTop]
        swift_scores = np.asarray([entry["score"] for entry in swiftTop], dtype=np.float32)
        numpy_scores = scores[order]

        slots_match = swift_slots == order.tolist()
        worst = float(np.abs(swift_scores - numpy_scores).max())
        print(f"  query {index}: slots match {slots_match}, "
              f"worst score delta {worst:.2e} (top score {numpy_scores[0]:.4f})")
        if not slots_match:
            print(f"    FAIL: swift {swift_slots[:5]} vs numpy {order[:5].tolist()}")
            problems += 1
        if worst > args.tolerance:
            print(f"    FAIL: score delta {worst} exceeds {args.tolerance}")
            problems += 1

    print()
    if problems == 0:
        print(f"RESULT: NumPy independently reproduces the Swift rankings "
              f"({len(payload['queries'])} queries, top {payload['topK']})")
        return 0
    print(f"RESULT: {problems} problems found")
    return 1


if __name__ == "__main__":
    sys.exit(main())
