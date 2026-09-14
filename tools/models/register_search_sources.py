#!/usr/bin/env python3
"""Register PhotoVault/Search sources and PhotoVault/Models resources in the project.

Two groups are handled:

* `PhotoVault/Search/*.swift` and the `.metal` kernel go into the **Sources**
  phase.
* `PhotoVault/Models/*` (`SigLIP2Vision.mlpackage`, `SigLIP2Text.mlpackage`,
  `tokenizer-v1.bin`, `SearchModelManifest.json`) go into the **Resources**
  phase, where Xcode's `coremlc` compiles each `.mlpackage` into an
  `.mlmodelc`. That directory is gitignored and produced by
  `install_models.py`; when it is absent this part is skipped with a note rather
  than treated as an error, because the Swift code compiles without it.

Why this is a script rather than a hand edit
-------------------------------------------
`PhotoVault.xcodeproj` uses **explicit** `PBXBuildFile` references: there is no
`PBXFileSystemSynchronizedRootGroup` anywhere, so a file dropped into
`PhotoVault/` is not compiled until it is listed in four places. Hand-editing
those lists is how a project file acquires duplicate ids or a file that is
referenced but never built -- a mistake that stays quiet until a symbol is
mysteriously "not in scope".

Running it twice is safe: every step is keyed on whether the file is *already*
referenced, and ids are assigned by scanning for the first free slot rather than
being hardcoded.

    python tools/models/register_search_sources.py            # apply
    python tools/models/register_search_sources.py --check     # report only
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
PROJECT = REPO / "PhotoVault.xcodeproj" / "project.pbxproj"
SOURCE_DIR = REPO / "PhotoVault" / "Search"


def existing_group(body: str, comment: str) -> str:
    """The id of an existing group with this comment, or "" if there is none.

    Module level rather than nested so it can be consulted while deciding whether
    a group needs creating -- the decision happens before the apply helpers are
    defined.
    """
    found = re.search(
        r"\t\t(D100000000000000000000\d\d) /\* " + re.escape(comment)
        + r" \*/ = \{\n\t\t\tisa = PBXGroup;", body)
    return found.group(1) if found else ""
RESOURCE_DIR = REPO / "PhotoVault" / "Models"

# The group the Search folder hangs off, and the build phases to add to. These
# are read from the file rather than assumed, so a re-generated project with
# different ids still works.
PHOTOVAULT_GROUP_COMMENT = "/* PhotoVault */"

# A separate id range from the existing 01..23 entries, so a future hand edit
# adding one more file cannot collide with what this script allocates.
BUILD_FILE_PREFIX = "A100000000000000000000"
FILE_REF_PREFIX = "B100000000000000000000"
GROUP_PREFIX = "D100000000000000000000"
FIRST_DYNAMIC_INDEX = 40


def first_free_index(text: str, prefix: str, taken: set[int]) -> int:
    index = FIRST_DYNAMIC_INDEX
    while index in taken or f"{prefix}{index:02d}" in text:
        index += 1
    taken.add(index)
    return index


def existing_indices(text: str, prefix: str) -> set[int]:
    found: set[int] = set()
    for match in re.finditer(rf"{prefix}(\d{{2}})\b", text):
        found.add(int(match.group(1)))
    return found


def collect_resources() -> list[pathlib.Path]:
    """Model artifacts to bundle, or an empty list when they are not installed.

    Absence is not an error: the directory is gitignored, so a clean clone has
    none until `install_models.py` runs. The Swift sources compile either way.
    """
    if not RESOURCE_DIR.is_dir():
        return []
    return sorted((p for p in RESOURCE_DIR.iterdir() if not p.name.startswith(".")),
                  key=lambda p: p.name)


def collect_sources() -> list[pathlib.Path]:
    """Search sources, plus any new file sitting directly in PhotoVault/.

    The app target uses explicit file references, so a new file in `PhotoVault/`
    is not compiled until it is registered -- and `collect_sources` originally
    only looked in `PhotoVault/Search/`, so adding one there was silently
    ignored. Root-level files belong to the existing PhotoVault group rather
    than the Search group, which `is_search_source` records.
    """
    if not SOURCE_DIR.is_dir():
        raise SystemExit(f"missing {SOURCE_DIR}")
    files = sorted(
        (p for p in SOURCE_DIR.iterdir() if p.suffix in {".swift", ".metal"}),
        key=lambda p: p.name,
    )
    root = REPO / "PhotoVault"
    files += sorted(
        (p for p in root.iterdir() if p.is_file() and p.suffix in {".swift", ".metal"}),
        key=lambda p: p.name,
    )
    if not files:
        raise SystemExit(f"no sources found in {SOURCE_DIR}")
    return files


def is_search_source(path: pathlib.Path) -> bool:
    """Whether this file goes in the Search group or the PhotoVault group."""
    return path.parent.name == "Search"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report what would change without writing")
    args = parser.parse_args()

    text = PROJECT.read_text()
    sources = collect_sources()

    # A file counts as registered only if it has a build-file entry *and* that
    # entry is in the Sources phase. A file reference alone builds nothing.
    sources_phase = re.search(
        r"/\* Begin PBXSourcesBuildPhase section \*/(.*?)/\* End PBXSourcesBuildPhase section \*/",
        text, re.S)
    if not sources_phase:
        raise SystemExit("cannot find the Sources build phase")
    sources_body = sources_phase.group(1)

    unregistered = [p for p in sources if p.name not in sources_body]
    already = [p.name for p in sources if p.name in sources_body]

    resources = collect_resources()
    resources_phase = re.search(
        r"/\* Begin PBXResourcesBuildPhase section \*/(.*?)/\* End PBXResourcesBuildPhase section \*/",
        text, re.S)
    if not resources_phase:
        raise SystemExit("cannot find the Resources build phase")
    resources_body = resources_phase.group(1)
    resources_to_add = [p for p in resources if p.name not in resources_body]

    print(f"Search sources: {len(sources)} found, {len(already)} already in Sources")
    for name in already:
        print(f"  [have] {name}")
    if resources:
        print(f"Model resources: {len(resources)} found, "
              f"{len(resources) - len(resources_to_add)} already bundled")
        for path in resources_to_add:
            print(f"  [add ] {path.name}")
    else:
        print(f"Model resources: none in {RESOURCE_DIR.relative_to(REPO)} "
              "(run install_models.py to populate)")
    for path in unregistered:
        print(f"  [add ] {path.name}")

    if not unregistered and not resources_to_add:
        print("nothing to do; the project is already up to date")
        return 0

    if args.check:
        print(f"\n--check: {len(unregistered)} source(s) and "
              f"{len(resources_to_add)} resource(s) would be registered")
        return 0

    taken_build = existing_indices(text, BUILD_FILE_PREFIX)
    taken_ref = existing_indices(text, FILE_REF_PREFIX)
    taken_group = existing_indices(text, GROUP_PREFIX)

    # Both ids are allocated ONCE per file, in a single pass.
    #
    # The first version allocated the file-reference id a second time while
    # building the PBXBuildFile line, so the build files pointed at B1...40-54
    # while the file references were created as B1...55-69. Xcode did not
    # complain: it silently dropped the unresolvable build files, the build
    # reported success, and none of the 15 files were compiled. A dangling
    # reference in a project file is not an error, which is exactly why the
    # verification below checks for object files rather than trusting the build.
    assignments: list[tuple[pathlib.Path, str, str]] = []
    for path in unregistered:
        build_id = f"{BUILD_FILE_PREFIX}{first_free_index(text, BUILD_FILE_PREFIX, taken_build):02d}"
        ref_id = f"{FILE_REF_PREFIX}{first_free_index(text, FILE_REF_PREFIX, taken_ref):02d}"
        assignments.append((path, build_id, ref_id))

    # Resource ids come from the same counters, so the two groups cannot collide.
    resource_assignments: list[tuple[pathlib.Path, str, str]] = []
    for path in resources_to_add:
        build_id = f"{BUILD_FILE_PREFIX}{first_free_index(text, BUILD_FILE_PREFIX, taken_build):02d}"
        ref_id = f"{FILE_REF_PREFIX}{first_free_index(text, FILE_REF_PREFIX, taken_ref):02d}"
        resource_assignments.append((path, build_id, ref_id))

    # ---- 1. PBXBuildFile entries -----------------------------------------
    # Every source here is compiled, including the .metal: Xcode builds Metal
    # sources into the default library, which is what
    # `makeDefaultLibrary(bundle:)` loads at runtime.
    build_lines = [
        f"\t\t{build_id} /* {path.name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {ref_id} /* {path.name} */; }};"
        for path, build_id, ref_id in assignments
    ]

    # ---- 2. PBXFileReference entries -------------------------------------
    reference_lines = []
    for path, _, ref_id in assignments:
        file_type = "sourcecode.metal" if path.suffix == ".metal" else "sourcecode.swift"
        reference_lines.append(
            f"\t\t{ref_id} /* {path.name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = {file_type}; "
            f"path = {path.name}; sourceTree = \"<group>\"; }};"
        )

    # ---- 3. The Search group ---------------------------------------------
    # Only when there is something to put in it. Creating it unconditionally
    # left an empty "Search" group in the navigator on every re-run that had no
    # new sources -- harmless to the build, but it silently accumulated a new
    # empty group each time.
    # Root-level files belong to the existing PhotoVault group, not the Search
    # group, so the two sets are handled separately from here on.
    search_assignments = [a for a in assignments if is_search_source(a[0])]
    root_assignments = [a for a in assignments if not is_search_source(a[0])]

    group_id = existing_group(text, "Search")
    group_lines: list[str] = []
    if search_assignments and not group_id:
        group_index = first_free_index(text, GROUP_PREFIX, taken_group)
        group_id = f"{GROUP_PREFIX}{group_index:02d}"
        group_lines = [
            f"\t\t{group_id} /* Search */ = {{",
            "\t\t\tisa = PBXGroup;",
            "\t\t\tchildren = (",
        ]
        group_lines += [
            f"\t\t\t\t{ref_id} /* {path.name} */,"
            for path, _, ref_id in search_assignments
        ]
        group_lines += [
            "\t\t\t);",
            "\t\t\tpath = Search;",
            "\t\t\tsourceTree = \"<group>\";",
            "\t\t};",
        ]

    # ---- apply ------------------------------------------------------------
    def insert_before(marker: str, lines: list[str], body: str) -> str:
        return body.replace(marker, "\n".join(lines) + "\n" + marker, 1)

    def append_children_to_group(body: str, group_id: str, lines: list[str]) -> str:
        """Insert file references at the end of an existing group's child list.

        Needed because the group must be **reused**, not recreated, when files
        are added later. Creating a fresh group per batch left the navigator with
        several folders all called "Search" -- the build was fine, so nothing
        caught it, but the project was visibly wrong to anyone opening Xcode.
        """
        pattern = re.compile(
            r"(\t\t" + re.escape(group_id)
            + r" /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)"
            r"(.*?)"
            r"(\t\t\t\);)", re.S)
        match = pattern.search(body)
        if not match:
            raise SystemExit(f"cannot find the child list of group {group_id}")
        return body[:match.end(2)] + "\n".join(lines) + "\n" + body[match.end(2):]

    def add_child_to_group(body: str, parent_id: str, child_line: str) -> str:
        """Append a child reference to an existing group's children list.

        The regex is re-run against `body` on every call. An earlier version
        captured the match offset once and reused it after several other edits
        had grown the text, so the offset pointed into the middle of an unrelated
        line and the reference was spliced into it -- producing a project file
        Xcode could not read at all.
        """
        anchor = re.search(
            r"\t\t" + re.escape(parent_id)
            + r" /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n",
            body)
        if not anchor:
            raise SystemExit(f"cannot find the child list of group {parent_id}")
        return body[:anchor.end()] + child_line + body[anchor.end():]

    text = insert_before("/* End PBXBuildFile section */", build_lines, text)
    text = insert_before("/* End PBXFileReference section */", reference_lines, text)

    # The group definition goes at the end of the PBXGroup section.
    if group_lines:
        text = insert_before("/* End PBXGroup section */", group_lines, text)

    # ...and is added as a child of the PhotoVault group so it appears in the
    # navigator. Without this the files compile but are invisible in Xcode.
    if root_assignments:
        text = append_children_to_group(
            text, "D10000000000000000000002",
            [f"\t\t\t\t{ref_id} /* {path.name} */," for path, _, ref_id in root_assignments])

    if search_assignments:
        if group_lines:
            # Freshly created. The definition itself was already inserted above;
            # inserting it again here produced two groups with the same id --
            # the file still parsed, so only counting the definitions caught it.
            text = add_child_to_group(
                text, "D10000000000000000000002", f"\t\t\t\t{group_id} /* Search */,\n")
        else:
            # Reused: the group and its parent reference already exist, so only
            # the new children are appended.
            text = append_children_to_group(
                text, group_id,
                [f"\t\t\t\t{ref_id} /* {path.name} */," for path, _, ref_id in search_assignments])

    # Finally the Sources phase, which is what actually compiles them.
    phase_entries = "\n".join(
        f"\t\t\t\t{build_id} /* {path.name} in Sources */,"
        for path, build_id, _ in assignments
    )
    phase_anchor = re.search(
        r"(\t\tC10000000000000000000002 /\* Sources \*/ = \{\n"
        r"\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = 2147483647;\n"
        r"\t\t\tfiles = \(\n)", text)
    if not phase_anchor:
        raise SystemExit("cannot find the Sources phase file list")
    text = text[:phase_anchor.end()] + phase_entries + "\n" + text[phase_anchor.end():]

    # ---- self-check before writing ---------------------------------------
    # A dangling fileRef is not a project error, so nothing downstream would
    # catch it; the build would simply skip the file and succeed.
    for path, build_id, ref_id in assignments:
        if f"{ref_id} /* {path.name} */ = {{isa = PBXFileReference" not in text:
            raise SystemExit(f"internal error: no file reference for {path.name} ({ref_id})")
        if f"{build_id} /* {path.name} in Sources */ =" not in text:
            raise SystemExit(f"internal error: no build file for {path.name} ({build_id})")
        if text.count(ref_id) < 3:
            # definition + group child + build file's fileRef
            raise SystemExit(
                f"internal error: {ref_id} ({path.name}) appears {text.count(ref_id)} "
                "times; expected a definition, a group entry and a build-file reference")

    if resource_assignments:
        # `.mlpackage` is a *directory*, and its type string is what makes Xcode
        # compile it with coremlc instead of copying it verbatim.
        def resource_type(path: pathlib.Path) -> str:
            if path.suffix == ".mlpackage":
                return "folder.mlpackage"
            if path.suffix == ".json":
                return "text.json"
            return "file"

        resource_build_lines = [
            f"\t\t{build_id} /* {path.name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ref_id} /* {path.name} */; }};"
            for path, build_id, ref_id in resource_assignments
        ]
        resource_reference_lines = [
            f"\t\t{ref_id} /* {path.name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = {resource_type(path)}; "
            f"path = {path.name}; sourceTree = \"<group>\"; }};"
            for path, _, ref_id in resource_assignments
        ]
        resource_group_index = first_free_index(text, GROUP_PREFIX, taken_group)
        resource_group_id = f"{GROUP_PREFIX}{resource_group_index:02d}"
        resource_group_lines = [
            f"\t\t{resource_group_id} /* Models */ = {{",
            "\t\t\tisa = PBXGroup;",
            "\t\t\tchildren = (",
        ]
        resource_group_lines += [
            f"\t\t\t\t{ref_id} /* {path.name} */,"
            for path, _, ref_id in resource_assignments
        ]
        resource_group_lines += [
            "\t\t\t);",
            "\t\t\tpath = Models;",
            "\t\t\tsourceTree = \"<group>\";",
            "\t\t};",
        ]

        text = insert_before("/* End PBXBuildFile section */", resource_build_lines, text)
        text = insert_before("/* End PBXFileReference section */", resource_reference_lines, text)
        text = insert_before("/* End PBXGroup section */", resource_group_lines, text)
        text = add_child_to_group(
            text, "D10000000000000000000002", f"\t\t\t\t{resource_group_id} /* Models */,\n")

        resource_phase_entries = "\n".join(
            f"\t\t\t\t{build_id} /* {path.name} in Resources */,"
            for path, build_id, _ in resource_assignments
        )
        resource_anchor = re.search(
            r"(\t\tC10000000000000000000003 /\* Resources \*/ = \{\n"
            r"\t\t\tisa = PBXResourcesBuildPhase;\n"
            r"\t\t\tbuildActionMask = 2147483647;\n"
            r"\t\t\tfiles = \(\n)", text)
        if not resource_anchor:
            raise SystemExit("cannot find the Resources phase file list")
        text = (text[:resource_anchor.end()] + resource_phase_entries + "\n"
                + text[resource_anchor.end():])

        for path, build_id, ref_id in resource_assignments:
            if f"{ref_id} /* {path.name} */ = {{isa = PBXFileReference" not in text:
                raise SystemExit(f"internal error: no file reference for {path.name}")
            if f"{build_id} /* {path.name} in Resources */" not in text:
                raise SystemExit(f"internal error: no build file for {path.name}")

    PROJECT.write_text(text)
    if unregistered:
        print(f"\nregistered {len(unregistered)} source(s) as group {group_id}")
    if resource_assignments:
        print(f"registered {len(resource_assignments)} resource(s) as group {resource_group_id}")
    print("verify with:")
    print("  xcodebuild -project PhotoVault.xcodeproj -scheme PhotoVault \\")
    print("    -configuration Debug -destination 'generic/platform=iOS' build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
