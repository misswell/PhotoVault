#!/usr/bin/env python3
"""Copy the converted SigLIP2 artifacts into the app target's resource folder.

Why the artifacts are not in git
--------------------------------
The W8 build is **364 MB** (89 MB vision + 270 MB text + 5 MB tokenizer) and the
FP16 build is 715 MB. Both are fully reproducible from
`tools/models/requirements-lock.txt` plus `convert_siglip2.py`, so
`PhotoVault/Models/` is ignored and populated by this script.

The consequence is real and worth stating: **a clean clone cannot build a working
app until this has been run once.** That is the deliberate trade -- a repository
that stays small and reviewable, at the cost of one reproducible step. The build
does not fail without it (no Swift source references these files at compile
time); search simply has no model to load, and `SearchModelResources` reports
that clearly rather than crashing.

    python tools/models/install_models.py              # install W8 (the default)
    python tools/models/install_models.py --precision fp16
    python tools/models/install_models.py --check       # report only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = HERE / "out"
BUILD = HERE / "build"
DESTINATION = REPO / "PhotoVault" / "Models"

# App-facing names. The pipeline keeps "ImageEncoder"/"TextEncoder"; the app
# calls them vision and text because that is the tower each one is.
ARTIFACTS = {
    "w8": {
        "SigLIP2Vision.mlpackage": OUT / "SigLIP2ImageEncoder-w8.mlpackage",
        "SigLIP2Text.mlpackage": OUT / "SigLIP2TextEncoder-w8.mlpackage",
    },
    "fp16": {
        "SigLIP2Vision.mlpackage": OUT / "SigLIP2ImageEncoder.mlpackage",
        "SigLIP2Text.mlpackage": OUT / "SigLIP2TextEncoder.mlpackage",
    },
}

TOKENIZER_SOURCE = BUILD / "tokenizer-v1.bin"
TOKENIZER_NAME = "tokenizer-v1.bin"
MANIFEST_SOURCE = OUT / "model_manifest.json"
MANIFEST_NAME = "SearchModelManifest.json"


def directory_size(path: pathlib.Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def human(count: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if count < 1024 or unit == "GB":
            return f"{count:.1f} {unit}" if unit != "B" else f"{count} B"
        count /= 1024
    return f"{count:.1f} GB"


def tree_digest(path: pathlib.Path) -> str:
    """A digest over the tree's file names and contents.

    `mlpackage` is a directory, so a plain file hash will not do; hashing the
    sorted relative paths plus each file's bytes catches both a changed weight
    file and a missing one.
    """
    digest = hashlib.sha256()
    for entry in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(str(entry.relative_to(path)).encode())
        with entry.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--precision", choices=("w8", "fp16"), default="w8",
                        help="which converted build to install (default: w8)")
    parser.add_argument("--check", action="store_true",
                        help="report what would be installed without copying")
    parser.add_argument("--force", action="store_true",
                        help="re-copy even when the destination matches")
    parser.add_argument("--appendix", action="store_true",
                        help="also record per-file SHA-256 in the copied manifest")
    args = parser.parse_args()

    selected = ARTIFACTS[args.precision]
    missing = [str(p) for p in selected.values() if not p.exists()]
    if not TOKENIZER_SOURCE.exists():
        missing.append(str(TOKENIZER_SOURCE))
    if missing:
        print("missing artifacts; run the conversion first:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        print("\n  python tools/models/convert_siglip2.py --quantize w8", file=sys.stderr)
        return 1

    total = sum(directory_size(p) for p in selected.values()) + TOKENIZER_SOURCE.stat().st_size
    print(f"precision: {args.precision}")
    for name, source in selected.items():
        print(f"  {name}  <- {source.name}  ({human(directory_size(source))})")
    print(f"  {TOKENIZER_NAME}  <- {TOKENIZER_SOURCE.name}  ({human(TOKENIZER_SOURCE.stat().st_size)})")
    print(f"  total on disk: {human(total)}")

    if args.check:
        print(f"\n--check: would install into {DESTINATION.relative_to(REPO)}")
        return 0

    DESTINATION.mkdir(parents=True, exist_ok=True)

    for name, source in selected.items():
        target = DESTINATION / name
        # Skipping an unchanged model matters more than it looks: re-copying
        # 270 MB on every build would make the install step something people
        # avoid running.
        if target.exists() and not args.force:
            if tree_digest(target) == tree_digest(source):
                print(f"  [skip] {name} (already identical)")
                continue
            shutil.rmtree(target)
        elif target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)
        print(f"  [copy] {name}")

    tokenizer_target = DESTINATION / TOKENIZER_NAME
    if not tokenizer_target.exists() or tokenizer_target.read_bytes() != TOKENIZER_SOURCE.read_bytes():
        shutil.copy2(TOKENIZER_SOURCE, tokenizer_target)
        print(f"  [copy] {TOKENIZER_NAME}")
    else:
        print(f"  [skip] {TOKENIZER_NAME} (already identical)")

    # The manifest is the app's contract: which model, which dimension, which
    # source revision and licence. It is copied under an app-facing name and
    # keeps the source SHA that the store records alongside every embedding.
    manifest = json.loads(MANIFEST_SOURCE.read_text())
    manifest["installedPrecision"] = args.precision
    manifest["installedFiles"] = sorted(list(selected.keys()) + [TOKENIZER_NAME])
    if args.appendix:
        manifest["installedSHA256"] = {
            name: tree_digest(DESTINATION / name) for name in selected
        }
        manifest["installedSHA256"][TOKENIZER_NAME] = hashlib.sha256(
            tokenizer_target.read_bytes()).hexdigest()
    (DESTINATION / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"  [write] {MANIFEST_NAME}")

    print(f"\ninstalled into {DESTINATION.relative_to(REPO)}")
    print("next:")
    print("  python tools/models/register_search_sources.py   # register as resources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
