#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact="${1:-$repository_root/dist/release/xcframework/Libmpv.xcframework}"
temporary_root=""

# Symbol presence alone cannot prove that the cached native source included the latest behavioral
# patches. When validating this checkout's own build, require the patch-set stamp and a marker from
# the final restore-worker patch so an older cached mpv tree cannot silently produce the release.
if [[ "$artifact" == "$repository_root/dist/release/xcframework/Libmpv.xcframework" ]]; then
    native_source="$repository_root/dist/libmpv-v0.41.0"
    patch_stamp="$native_source/.mpvkit-patch-set"
    expected_patch_stamp=""
    while IFS= read -r patch; do
        encoded="$(/usr/bin/base64 < "$patch" | tr -d '\r\n')"
        if [[ -n "$expected_patch_stamp" ]]; then
            expected_patch_stamp+=$'\n'
        fi
        expected_patch_stamp+="$(basename "$patch"):$encoded"
    done < <(find "$repository_root/Sources/BuildScripts/patch/libmpv" \
        -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)
    if [[ ! -f "$patch_stamp" ]] \
       || [[ "$(cat "$patch_stamp")" != "$expected_patch_stamp" ]] \
       || ! grep -Fq 'inline_callback_pending' "$native_source/video/out/vo_gpu_next.c"; then
        echo "Built Libmpv source does not contain the current serialized PiP restore patch set." >&2
        exit 1
    fi
fi

cleanup() {
    if [[ -n "$temporary_root" ]]; then
        rm -rf "$temporary_root"
    fi
}
trap cleanup EXIT

if [[ -f "$artifact" && "$artifact" == *.zip ]]; then
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-built-symbols.XXXXXX")"
    /usr/bin/unzip -q "$artifact" -d "$temporary_root"
    artifact="$(find "$temporary_root" -maxdepth 2 -type d -name 'Libmpv.xcframework' -print -quit)"
fi

if [[ ! -d "$artifact" ]]; then
    echo "Libmpv XCFramework not found: $artifact" >&2
    exit 1
fi

plist="$artifact/Info.plist"
for platform in ios; do
    if ! /usr/bin/plutil -p "$plist" | grep -Fq "\"SupportedPlatform\" => \"$platform\""; then
        echo "Libmpv XCFramework is missing its $platform slice." >&2
        exit 1
    fi
done

pip_symbols=(
    mpv_apple_pip_api_version
    mpv_apple_pip_get_capabilities
    mpv_apple_pip_set_callback
    mpv_apple_pip_set_mode
    mpv_apple_pip_submit_target
    mpv_apple_pip_disable_and_drain
)

binary_count=0
while IFS= read -r binary; do
    binary_count=$((binary_count + 1))
    exported="$(nm -gU "$binary")"
    if [[ "$artifact" == "$repository_root/dist/release/xcframework/Libmpv.xcframework" ]] \
       && [[ "$binary" == */ios-* && "$binary" != *maccatalyst* ]] \
       && { ! grep -Fq 'requesting synchronized audio output recovery' "$binary" \
           || ! grep -Fq 'preserving playback position during AVFoundation recovery' "$binary"; }; then
        echo "Missing synchronized AVFoundation audio recovery in iOS slice: $binary" >&2
        exit 1
    fi
    for symbol in "${pip_symbols[@]}"; do
        if ! grep -q " _$symbol$" <<<"$exported"; then
            echo "Missing $symbol in built slice: $binary" >&2
            exit 1
        fi
    done
    # The guarded AudioUnit recovery hook is intentionally iOS/tvOS-only. macOS keeps its
    # separate CoreAudio recovery path and therefore need not link ao_audiounit.m at all.
    if [[ "$binary" != *macos-* ]] \
       && ! grep -q ' _mpv_apple_audiounit_recovery_count$' <<<"$exported"; then
        echo "Missing mpv_apple_audiounit_recovery_count in built mobile slice: $binary" >&2
        exit 1
    fi
done < <(find "$artifact" -type f -name Libmpv -print | LC_ALL=C sort)

if [[ "$binary_count" -lt 2 ]]; then
    echo "Expected iOS device and simulator Libmpv binaries; found $binary_count." >&2
    exit 1
fi

echo "Validated retained Apple PiP symbols in $binary_count iOS Libmpv slices and AudioUnit recovery."
