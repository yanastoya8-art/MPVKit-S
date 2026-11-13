#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-package-routing.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

create_fixture() {
    local fixture_name="$1"
    local mutation="$2"
    local fixture_root="$temporary_root/$fixture_name"

    mkdir -p "$fixture_root"
    cp "$repository_root/Package.swift" "$fixture_root/Package.swift"

    python3 - "$fixture_root" "$mutation" <<'PY'
import copy
import hashlib
import json
import os
import plistlib
import shutil
import sys

root, mutation = sys.argv[1:]
artifacts_root = os.path.join(root, "dist", "release", "xcframework")
os.makedirs(artifacts_root, exist_ok=True)

required_artifacts = [
    "Libmpv",
    "MoltenVK",
    "Libplacebo",
    "Libavcodec",
    "Libavdevice",
    "Libavfilter",
    "Libavformat",
    "Libavutil",
    "Libswresample",
    "Libswscale",
]

active_matrix = [
    {
        "LibraryIdentifier": "ios-arm64",
        "LibraryPath": "Fixture.framework",
        "SupportedArchitectures": ["arm64"],
        "SupportedPlatform": "ios",
    },
    {
        "LibraryIdentifier": "ios-arm64_x86_64-simulator",
        "LibraryPath": "Fixture.framework",
        "SupportedArchitectures": ["arm64", "x86_64"],
        "SupportedPlatform": "ios",
        "SupportedPlatformVariant": "simulator",
    },

]

def write_artifact(path, libraries):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "Info.plist"), "wb") as handle:
        plistlib.dump(
            {
                "AvailableLibraries": libraries,
                "CFBundlePackageType": "XFWK",
                "XCFrameworkFormatVersion": "1.0",
            },
            handle,
        )

for artifact_name in required_artifacts:
    if mutation == "missing-libplacebo" and artifact_name == "Libplacebo":
        continue
    if mutation == "zip-only":
        with open(os.path.join(artifacts_root, f"{artifact_name}.xcframework.zip"), "wb") as handle:
            handle.write(b"fixture")
        continue

    libraries = copy.deepcopy(active_matrix)
    if artifact_name == "Libmpv":
        if mutation.startswith("missing-slice:"):
            missing_identifier = mutation.split(":", 1)[1]
            libraries = [
                library
                for library in libraries
                if library["LibraryIdentifier"] != missing_identifier
            ]
        elif mutation.startswith("missing-architecture:"):
            identifier, architecture = mutation.split(":", 1)[1].split(",", 1)
            for library in libraries:
                if library["LibraryIdentifier"] == identifier:
                    library["SupportedArchitectures"].remove(architecture)

    artifact = os.path.join(artifacts_root, f"{artifact_name}.xcframework")
    if artifact_name == "MoltenVK":
        for library in libraries:
            library["BinaryPath"] = "libMoltenVK.a"
            library["LibraryPath"] = "libMoltenVK.a"
    write_artifact(artifact, libraries)
    if artifact_name == "MoltenVK":
        for library in libraries:
            binary = os.path.join(
                artifact,
                library["LibraryIdentifier"],
                library["BinaryPath"],
            )
            os.makedirs(os.path.dirname(binary), exist_ok=True)
            with open(binary, "wb") as handle:
                handle.write(f"fixture:{library['LibraryIdentifier']}".encode())

release_root = os.path.dirname(artifacts_root)
molten_artifact = os.path.join(artifacts_root, "MoltenVK.xcframework")
if os.path.isdir(molten_artifact):
    info_plist = os.path.join(molten_artifact, "Info.plist")
    with open(info_plist, "rb") as handle:
        info_hash = hashlib.sha256(handle.read()).hexdigest()
    slice_hashes = {}
    platform_slices = {}
    for library in active_matrix:
        identifier = library["LibraryIdentifier"]
        binary = os.path.join(molten_artifact, identifier, "libMoltenVK.a")
        with open(binary, "rb") as handle:
            slice_hashes[identifier] = hashlib.sha256(handle.read()).hexdigest()
        platform_slices[identifier] = library["SupportedArchitectures"]
    marker = {
        "schema": 1,
        "feature": "imported-mtltexture-residency-fix",
        "artifact": "xcframework/MoltenVK.xcframework",
        "base": {
            "repository": "https://github.com/KhronosGroup/MoltenVK",
            "tag": "v1.4.1",
            "commit": "db445ff2042d9ce348c439ad8451112f354b8d2a",
        },
        "backport": {
            "source_commit": "a17d4d53359d8c029406cbe2c50d9a0089964035",
            "merge_commit": "32dceb35e2c95b46cec501033cbc3a1ddf32d6e8",
            "patch_sha256": "d0d37d938d466f0a5504368ad0df83143150e303af014ded7af8947bf8136ee2",
        },
        "build": {"platform_slices": platform_slices},
        "integrity": {
            "info_plist_sha256": info_hash,
            "slice_sha256": slice_hashes,
        },
    }
    if mutation == "marker-stale-hash":
        marker["integrity"]["slice_sha256"]["ios-arm64"] = "0" * 64
    marker_path = os.path.join(release_root, "MoltenVK.imported-mtltexture-residency-fix")
    if mutation == "marker-empty":
        open(marker_path, "wb").close()
    elif mutation == "marker-symlink":
        target = os.path.join(release_root, "MoltenVK.marker-target.json")
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(marker, handle, sort_keys=True)
        os.symlink(target, marker_path)
    else:
        with open(marker_path, "w", encoding="utf-8") as handle:
            json.dump(marker, handle, sort_keys=True)

    if mutation == "molten-binary-symlink":
        binary = os.path.join(molten_artifact, "ios-arm64", "libMoltenVK.a")
        target = os.path.join(release_root, "MoltenVK-ios-arm64-target.a")
        shutil.move(binary, target)
        os.symlink(target, binary)

if mutation in {"partial-root-shadow", "complete-root-duplicate"}:
    libraries = copy.deepcopy(active_matrix)
    if mutation == "partial-root-shadow":
        libraries = [
            library for library in libraries
            if library["LibraryIdentifier"] != "ios-arm64"
        ]
    write_artifact(os.path.join(release_root, "Libmpv.xcframework"), libraries)
elif mutation == "partial-gpl-alias-shadow":
    libraries = [
        library for library in copy.deepcopy(active_matrix)
        if library["LibraryIdentifier"] != "ios-arm64"
    ]
    write_artifact(os.path.join(release_root, "Libmpv-GPL.xcframework"), libraries)
elif mutation in {"canonical-zip-shadow", "gpl-zip-shadow"}:
    name = "Libmpv" if mutation == "canonical-zip-shadow" else "Libmpv-GPL"
    with open(os.path.join(release_root, f"{name}.xcframework.zip"), "wb") as handle:
        handle.write(b"fixture")
elif mutation == "artifact-symlink":
    artifact = os.path.join(artifacts_root, "Libmpv.xcframework")
    target = os.path.join(root, "outside-artifact", "Libmpv.xcframework")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.move(artifact, target)
    os.symlink(target, artifact)
elif mutation == "info-plist-symlink":
    info_plist = os.path.join(artifacts_root, "Libmpv.xcframework", "Info.plist")
    target = os.path.join(root, "outside-artifact", "Libmpv.Info.plist")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.move(info_plist, target)
    os.symlink(target, info_plist)
PY

    MPVKIT_LOCAL_ARTIFACTS_DIR= \
        swift package dump-package --package-path "$fixture_root" \
        > "$fixture_root/dump.json"
}

assert_remote_routing() {
    local fixture_name="$1"
    python3 - "$temporary_root/$fixture_name/dump.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)

targets = {target["name"]: target for target in package["targets"]}
for name in ["Libmpv-GPL", "MoltenVK", "Libplacebo", "Libavcodec-GPL"]:
    target = targets[name]
    if "url" not in target or "path" in target:
        raise SystemExit(f"{name} unexpectedly selected a partial local runtime: {target}")
PY
}

assert_local_routing() {
    local fixture_name="$1"
    local dump_name="${2:-dump.json}"
    python3 - "$temporary_root/$fixture_name/$dump_name" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)

expected = {
    "Libmpv-GPL": "Libmpv.xcframework",
    "MoltenVK": "MoltenVK.xcframework",
    "Libplacebo": "Libplacebo.xcframework",
    "Libavcodec-GPL": "Libavcodec.xcframework",
    "Libavdevice-GPL": "Libavdevice.xcframework",
    "Libavfilter-GPL": "Libavfilter.xcframework",
    "Libavformat-GPL": "Libavformat.xcframework",
    "Libavutil-GPL": "Libavutil.xcframework",
    "Libswresample-GPL": "Libswresample.xcframework",
    "Libswscale-GPL": "Libswscale.xcframework",
}
targets = {target["name"]: target for target in package["targets"]}
for name, artifact in expected.items():
    target = targets[name]
    path = target.get("path")
    expected_path = f"dist/release/xcframework/{artifact}"
    if target.get("url") is not None or path != expected_path:
        raise SystemExit(f"{name} did not select the complete local runtime: {target}")
PY
}

assert_explicit_root_rejected() {
    local fixture_name="$1"
    local fixture_root="$temporary_root/$fixture_name"

    if MPVKIT_LOCAL_ARTIFACTS_DIR=dist/release \
        swift package dump-package --package-path "$fixture_root" \
        > "$fixture_root/explicit-dump.json" \
        2> "$fixture_root/explicit-error.txt"
    then
        echo "Explicit local root unexpectedly accepted incomplete fixture: $fixture_name" >&2
        exit 1
    fi
    if ! grep -Fq \
        "MPVKIT_LOCAL_ARTIFACTS_DIR must contain the complete unpacked active Eclipse runtime" \
        "$fixture_root/explicit-error.txt"
    then
        echo "Explicit local root failed without the bounded completeness diagnostic: $fixture_name" >&2
        exit 1
    fi
}

assert_explicit_root_selected() {
    local fixture_name="$1"
    local fixture_root="$temporary_root/$fixture_name"

    MPVKIT_LOCAL_ARTIFACTS_DIR=dist/release \
        swift package dump-package --package-path "$fixture_root" \
        > "$fixture_root/explicit-dump.json"
    assert_local_routing "$fixture_name" explicit-dump.json
}

assert_molten_define() {
    local fixture_name="$1"
    local expectation="$2"
    local dump_name="${3:-dump.json}"
    python3 - "$temporary_root/$fixture_name/$dump_name" "$expectation" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)
target = next(target for target in package["targets"] if target["name"] == "MPVKitSampleBufferGPL")
defines = {
    setting["kind"]["define"]["_0"]
    for setting in target.get("settings", [])
    if setting.get("tool") == "swift" and "define" in setting.get("kind", {})
}
present = "MPVKIT_MOLTENVK_IMPORTED_TEXTURE_RESIDENCY_FIX" in defines
expected = sys.argv[2] == "present"
if present != expected:
    raise SystemExit(f"MoltenVK provenance define expectation failed: {defines}")
PY
}

assert_explicit_root_escape_rejected() {
    local target_fixture="$1"
    local fixture_root="$temporary_root/explicit-root-escape"
    mkdir -p "$fixture_root/dist"
    cp "$repository_root/Package.swift" "$fixture_root/Package.swift"
    ln -s "$temporary_root/$target_fixture/dist/release" "$fixture_root/dist/escaped"

    if MPVKIT_LOCAL_ARTIFACTS_DIR=dist/escaped \
        swift package dump-package --package-path "$fixture_root" \
        > "$fixture_root/dump.json" \
        2> "$fixture_root/error.txt"
    then
        echo "Explicit local root symlink unexpectedly escaped the package checkout" >&2
        exit 1
    fi
    grep -Fq \
        "MPVKIT_LOCAL_ARTIFACTS_DIR must resolve inside the MPVKit checkout" \
        "$fixture_root/error.txt"
}

create_fixture missing-libplacebo missing-libplacebo
assert_remote_routing missing-libplacebo
assert_explicit_root_rejected missing-libplacebo

create_fixture zip-only zip-only
assert_remote_routing zip-only
assert_explicit_root_rejected zip-only

for mutation in \
    partial-root-shadow \
    partial-gpl-alias-shadow \
    canonical-zip-shadow \
    gpl-zip-shadow
do
    create_fixture "$mutation" "$mutation"
    assert_local_routing "$mutation"
    assert_explicit_root_selected "$mutation"
done

create_fixture complete-root-duplicate complete-root-duplicate
assert_remote_routing complete-root-duplicate
assert_explicit_root_rejected complete-root-duplicate

for mutation in artifact-symlink info-plist-symlink; do
    create_fixture "$mutation" "$mutation"
    assert_remote_routing "$mutation"
    assert_explicit_root_rejected "$mutation"
done

for mutation in marker-empty marker-stale-hash marker-symlink molten-binary-symlink; do
    create_fixture "$mutation" "$mutation"
    assert_local_routing "$mutation"
    assert_molten_define "$mutation" absent
    assert_explicit_root_selected "$mutation"
    assert_molten_define "$mutation" absent explicit-dump.json
done

for identifier in \
    ios-arm64 \
    ios-arm64_x86_64-simulator
do
    fixture_name="missing-${identifier}"
    create_fixture "$fixture_name" "missing-slice:${identifier}"
    assert_remote_routing "$fixture_name"
    assert_explicit_root_rejected "$fixture_name"
done

for requirement in \
    ios-arm64,arm64 \
    ios-arm64_x86_64-simulator,arm64 \
    ios-arm64_x86_64-simulator,x86_64
do
    fixture_name="missing-architecture-${requirement//[^[:alnum:]]/-}"
    create_fixture "$fixture_name" "missing-architecture:${requirement}"
    assert_remote_routing "$fixture_name"
    assert_explicit_root_rejected "$fixture_name"
done

create_fixture complete full
assert_local_routing complete
assert_molten_define complete present
assert_explicit_root_selected complete
assert_molten_define complete present explicit-dump.json
assert_explicit_root_escape_rejected complete

echo "Package manifest selected remote artifacts for automatic incomplete fixtures, rejected every explicit incomplete root, and selected only the complete active Eclipse runtime."
