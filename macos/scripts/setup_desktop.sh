#!/bin/bash
#
# LiteRT-LM Native Desktop Setup Script for Flutter Gemma (macOS)
#
# Downloads prebuilt LiteRT-LM accelerator libraries from GitHub and
# signs them for macOS sandbox/Gatekeeper.
# No Java, no JRE, no JAR — pure native.
#
# Usage: setup_desktop.sh <PODS_TARGET_SRCROOT> <APP_BUNDLE_PATH>

set -e

echo "=== LiteRT-LM Native Desktop Setup (macOS) ==="

# ============================================================================
# Configuration
# ============================================================================

# GitHub base URL for raw LFS file downloads
GITHUB_BASE_URL="https://github.com/google-ai-edge/LiteRT-LM/raw/main/prebuilt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODS_ROOT="${1:-$SCRIPT_DIR/..}"
APP_BUNDLE="${2:-}"

# Skip if not macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Skipping: not macOS"
    exit 0
fi

if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    echo "No valid app bundle path provided: $APP_BUNDLE"
    exit 0
fi

echo "App bundle: $APP_BUNDLE"

# Architecture detection — Apple Silicon has prebuilts, Intel builds from source
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    NATIVE_ARCH="macos_arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
    NATIVE_ARCH="macos_x86_64"
else
    echo "WARNING: Unsupported macOS architecture: $ARCH"
    exit 0
fi

# Libraries we need for macOS (arm64 + x86_64):
#   - liblitert_lm_capi.dylib — main C API library (built from source via native/build_litert_lm_dll.sh)
#   - Accelerator .dylib files — from LiteRT-LM/prebuilt/
PREBUILT_LIBS=(
    "liblitert_lm_capi.dylib"
    "libGemmaModelConstraintProvider.dylib"
    "libLiteRt.dylib"
    "libLiteRtMetalAccelerator.dylib"
    "libLiteRtTopKWebGpuSampler.dylib"
    "libLiteRtWebGpuAccelerator.dylib"
)

PLUGIN_ROOT="$(cd "$PODS_ROOT/.." && pwd)"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
NATIVES_DIR="$FRAMEWORKS_DIR/litertlm"
CACHE_DIR="$HOME/Library/Caches/flutter_gemma/prebuilt/$NATIVE_ARCH"

echo "Plugin root: $PLUGIN_ROOT"
echo "Frameworks:  $FRAMEWORKS_DIR"
echo "Architecture: $ARCH"

mkdir -p "$NATIVES_DIR"
mkdir -p "$CACHE_DIR"

# ============================================================================
# Helper: download a file if not cached, then codesign for macOS
# ============================================================================
download_if_not_cached() {
    local filename="$1"
    local dest_dir="$2"

    local cached_file="$CACHE_DIR/$filename"
    local dest_file="$dest_dir/$filename"

    # Already in output? Skip.
    if [ -f "$dest_file" ]; then
        echo "  [cached]   $filename"
        return
    fi

    # Check local cache
    if [ -f "$cached_file" ]; then
        cp "$cached_file" "$dest_file"
        sign_lib "$dest_file"
        echo "  [cache]    $filename"
        return
    fi

    # Check local dev paths:
    #   1. native/prebuilt/ (built by native/build_litert_lm_dll.sh)
    #   2. LiteRT-LM-ref/prebuilt/ (cloned repo)
    for local_path in \
        "$PLUGIN_ROOT/native/prebuilt/$NATIVE_ARCH/$filename" \
        "$PLUGIN_ROOT/../LiteRT-LM-ref/prebuilt/$NATIVE_ARCH/$filename"; do
        if [ -f "$local_path" ]; then
            cp "$local_path" "$dest_file"
            cp "$local_path" "$cached_file"
            sign_lib "$dest_file"
            echo "  [local]    $filename"
            return
        fi
    done

    # Download from GitHub (raw URL handles LFS redirect)
    # Note: liblitert_lm_capi.dylib is NOT on GitHub — it must be built locally
    local url="$GITHUB_BASE_URL/$NATIVE_ARCH/$filename"
    echo "  [download] $filename from GitHub..."
    if curl -fSL --retry 3 -o "$cached_file" "$url"; then
        cp "$cached_file" "$dest_file"
        sign_lib "$dest_file"
        echo "  [ok]       $filename"
    else
        if [ "$filename" = "liblitert_lm_capi.dylib" ]; then
            echo "  [MISSING]  $filename — run native/build_litert_lm_dll.sh to build from source" >&2
        else
            echo "  [FAILED]   $filename (URL: $url)" >&2
        fi
        rm -f "$cached_file"
    fi
}

# ============================================================================
# Helper: codesign a library for macOS sandbox / Gatekeeper
# ============================================================================
sign_lib() {
    local lib_path="$1"
    # Remove quarantine attribute (downloaded files get flagged)
    xattr -r -d com.apple.quarantine "$lib_path" 2>/dev/null || true

    # Sign with the same identity Xcode uses for the app when one is set
    # (Apple Development / Apple Distribution / Developer ID). Mac App Store
    # validation rejects nested code that is only ad-hoc signed, and the app's
    # own signature (applied after this phase) then seals these files.
    # Plain `flutter run` debug builds have no identity, so fall back to ad-hoc.
    local identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
    if [ -z "$identity" ] || [ "$identity" = "-" ]; then
        identity="-"
    fi
    if ! codesign --force --sign "$identity" --timestamp=none "$lib_path"; then
        echo "  [warn]     codesign with '$identity' failed for $(basename "$lib_path"), ad-hoc signing instead" >&2
        codesign --force --sign - "$lib_path" 2>/dev/null || true
    fi
}

# ============================================================================
# Install prebuilt accelerator libraries
# ============================================================================
install_prebuilt_libs() {
    echo ""
    echo "=== Installing prebuilt LiteRT-LM libraries ==="

    for lib in "${PREBUILT_LIBS[@]}"; do
        download_if_not_cached "$lib" "$NATIVES_DIR"
    done
}

# ============================================================================
# Universal C API library (arm64 + x86_64)
# ============================================================================
# The app is built as a universal binary, so the LiteRT-LM C API must contain
# BOTH slices regardless of which Mac performs the build. Picking libraries by
# `uname -m` (the build host) would silently ship an Intel-only engine to Apple
# silicon users when building on an Intel Mac, and vice versa.
#
# When both per-arch builds from native/build_litert_lm_dll.sh are present we
# merge them with lipo and bundle only that. Accelerator plugins are skipped:
# the app runs LiteRT-LM on the CPU backend, and Google only ships the GPU
# accelerators for arm64, which would leave a half-universal bundle.
install_universal_capi() {
    local arm="$PLUGIN_ROOT/native/prebuilt/macos_arm64/liblitert_lm_capi.dylib"
    local x86="$PLUGIN_ROOT/native/prebuilt/macos_x86_64/liblitert_lm_capi.dylib"

    # Both slices must be real Mach-O files (not Git LFS pointer stubs)
    if ! lipo -archs "$arm" 2>/dev/null | grep -qw arm64; then return 1; fi
    if ! lipo -archs "$x86" 2>/dev/null | grep -qw x86_64; then return 1; fi

    echo ""
    echo "=== Installing universal LiteRT-LM C API (arm64 + x86_64) ==="

    local universal_cache="$HOME/Library/Caches/flutter_gemma/prebuilt/macos_universal"
    local merged="$universal_cache/liblitert_lm_capi.dylib"
    mkdir -p "$universal_cache"

    # Rebuild the merged file whenever either slice is newer than it
    if [ ! -f "$merged" ] || [ "$arm" -nt "$merged" ] || [ "$x86" -nt "$merged" ]; then
        lipo -create "$arm" "$x86" -output "$merged.tmp" && mv -f "$merged.tmp" "$merged"
        # Give the merged library a sane install name instead of the bazel-out path
        install_name_tool -id "@rpath/litertlm/liblitert_lm_capi.dylib" "$merged" 2>/dev/null || true
        echo "  [lipo]     liblitert_lm_capi.dylib -> $(lipo -archs "$merged")"
    fi

    # Always overwrite: a stale single-arch copy from an earlier build must not survive
    cp -f "$merged" "$NATIVES_DIR/liblitert_lm_capi.dylib"
    sign_lib "$NATIVES_DIR/liblitert_lm_capi.dylib"

    # Remove single-arch accelerator leftovers from earlier host-arch builds
    for lib in "${PREBUILT_LIBS[@]}"; do
        [ "$lib" = "liblitert_lm_capi.dylib" ] && continue
        rm -f "$NATIVES_DIR/$lib"
    done
    echo "  [ok]       $(lipo -archs "$NATIVES_DIR/liblitert_lm_capi.dylib")"
    return 0
}

# ============================================================================
# Main
# ============================================================================
# Prefer the universal path; fall back to the legacy host-arch behaviour when
# only one architecture has been built locally.
if ! install_universal_capi; then
    install_prebuilt_libs
fi

# Summary
echo ""
echo "========================================"
echo "=== Setup complete ==="
echo "========================================"
echo "Natives dir: $NATIVES_DIR"
echo ""
echo "Bundled libraries:"
for f in "$NATIVES_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    size=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") ($size)"
done
