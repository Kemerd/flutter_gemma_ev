#!/bin/bash
#
# Builds the LiteRT-LM C API as a shared library (.so / .dylib / .a)
#
# Uses Bazel to compile from source. Run this ONCE per platform, then
# Flutter's build system bundles the result automatically.
#
# Output goes to native/prebuilt/<platform>/.
#
# Supports:
#   macOS  — arm64 (Apple Silicon), x86_64 (Intel)
#   iOS    — arm64 (device), arm64_sim (simulator)
#   Linux  — x86_64, aarch64
#
# Prerequisites: bazelisk/bazel, clang, python3, git
#                (iOS builds also need Xcode + Apple SDK)
#
# Usage:
#   ./build_litert_lm_dll.sh [--clean] [--ios] [--ios-sim] [/path/to/LiteRT-LM]
#
# Flags:
#   --clean    Wipe Bazel cache before building (full rebuild)
#   --ios      Cross-compile for iOS device (arm64, static library)
#   --ios-sim  Cross-compile for iOS simulator (arm64, static library)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================================================================
# Parse flags
# ============================================================================

CLEAN=false
IOS_DEVICE=false
IOS_SIM=false
LITERT_LM_DIR=""

for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN=true ;;
        --ios)     IOS_DEVICE=true ;;
        --ios-sim) IOS_SIM=true ;;
        *)         LITERT_LM_DIR="$arg" ;;
    esac
done

echo ""
echo "============================================"
echo "  LiteRT-LM C API Shared Library Builder"
echo "  (flutter_gemma desktop/iOS)"
echo "============================================"
echo ""

# ============================================================================
# Resolve LiteRT-LM source directory
# ============================================================================
# Searches common locations relative to the plugin and user home.
# Pass an explicit path as the first non-flag argument to override.

if [ -z "$LITERT_LM_DIR" ]; then
    for candidate in \
        "$PLUGIN_ROOT/../LiteRT-LM-FFI/../LiteRT-LM-ref" \
        "$PLUGIN_ROOT/../LiteRT-LM-ref" \
        "$PLUGIN_ROOT/../LiteRT-LM" \
        "$HOME/LiteRT-LM"; do
        if [ -f "$candidate/c/engine.h" ]; then
            LITERT_LM_DIR="$(cd "$candidate" && pwd)"
            break
        fi
    done
fi

if [ -z "$LITERT_LM_DIR" ] || [ ! -f "$LITERT_LM_DIR/c/engine.h" ]; then
    echo "ERROR: LiteRT-LM source not found." >&2
    echo "Pass path as argument or clone next to this plugin:" >&2
    echo "  git clone https://github.com/google-ai-edge/LiteRT-LM.git ../LiteRT-LM-ref" >&2
    exit 1
fi

# ============================================================================
# Detect platform & architecture
# ============================================================================
# iOS cross-compilation overrides the native arch detection. On macOS, both
# arm64 (Apple Silicon) and x86_64 (Intel) are supported — LiteRT-LM uses
# CPU backend which works on any architecture.

OS=$(uname -s)
ARCH=$(uname -m)

if [ "$IOS_DEVICE" = true ]; then
    # -----------------------------------------------------------------------
    # iOS device (arm64) — produces a static library (.a)
    # Dynamic libraries (.dylib) are not allowed on non-jailbroken iOS.
    # The .a gets linked into the Flutter iOS plugin framework at build time.
    # -----------------------------------------------------------------------
    NATIVE_ARCH="ios_arm64"
    LIB_EXT="a"
    BUILD_STATIC=true
    BAZEL_EXTRA="--apple_platform_type=ios --cpu=ios_arm64"
    echo "Target: iOS device (arm64, static library)"

elif [ "$IOS_SIM" = true ]; then
    # -----------------------------------------------------------------------
    # iOS simulator (arm64) — also a static library
    # -----------------------------------------------------------------------
    NATIVE_ARCH="ios_sim_arm64"
    LIB_EXT="a"
    BUILD_STATIC=true
    BAZEL_EXTRA="--apple_platform_type=ios --cpu=ios_sim_arm64"
    echo "Target: iOS simulator (arm64, static library)"

elif [ "$OS" = "Darwin" ]; then
    # -----------------------------------------------------------------------
    # macOS — shared library (.dylib), works on both arm64 and x86_64.
    # LiteRT-LM runs on CPU on all three desktop OSes; there's zero reason
    # to gate macOS builds to arm64 only when Linux x86_64 works fine.
    # -----------------------------------------------------------------------
    LIB_EXT="dylib"
    BUILD_STATIC=false
    BAZEL_EXTRA=""
    if [ "$ARCH" = "arm64" ]; then
        NATIVE_ARCH="macos_arm64"
    elif [ "$ARCH" = "x86_64" ]; then
        NATIVE_ARCH="macos_x86_64"
    else
        echo "ERROR: Unsupported macOS architecture: $ARCH" >&2
        exit 1
    fi

elif [ "$OS" = "Linux" ]; then
    LIB_EXT="so"
    BUILD_STATIC=false
    BAZEL_EXTRA=""
    case "$ARCH" in
        x86_64)  NATIVE_ARCH="linux_x86_64" ;;
        aarch64) NATIVE_ARCH="linux_arm64" ;;
        *)       echo "ERROR: Unsupported Linux architecture: $ARCH" >&2; exit 1 ;;
    esac

else
    echo "ERROR: Unsupported OS: $OS (use build_litert_lm_dll.ps1 for Windows)" >&2
    exit 1
fi

OUTPUT_DIR="$SCRIPT_DIR/prebuilt/$NATIVE_ARCH"
mkdir -p "$OUTPUT_DIR"

echo "LiteRT-LM source: $LITERT_LM_DIR"
echo "Platform:          $OS $ARCH -> $NATIVE_ARCH"
echo "Output dir:        $OUTPUT_DIR"
echo ""

# ============================================================================
# Verify tools
# ============================================================================

echo "Checking build tools..."

BAZEL=""
for cmd in bazelisk bazel; do
    if command -v "$cmd" &>/dev/null; then
        BAZEL="$cmd"
        echo "  Bazel: $(command -v $cmd)"
        break
    fi
done

if [ -z "$BAZEL" ]; then
    echo "ERROR: bazelisk or bazel not found in PATH" >&2
    echo "  Install: brew install bazelisk  OR  npm install -g @bazel/bazelisk" >&2
    exit 1
fi

# Wipe Bazel cache if --clean was passed
if [ "$CLEAN" = true ]; then
    echo ""
    echo "Running bazel clean --expunge (this wipes the entire cache)..."
    (cd "$LITERT_LM_DIR" && $BAZEL clean --expunge)
    echo "  Cache purged."
fi

echo ""

# ============================================================================
# Create temporary shared/static library target
# ============================================================================
# We temporarily patch the upstream LiteRT-LM source to:
#   1. Add a missing C API function (set_dispatch_lib_dir)
#   2. Create a Bazel cc_binary target with linkshared=True (or cc_library
#      for static builds)
#   3. Force-export all C API symbols via explicit references
#
# Everything is restored on exit (even on error) via the cleanup trap.

echo "Setting up build target..."

BUILD_FILE="$LITERT_LM_DIR/c/BUILD"
STUB_FILE="$LITERT_LM_DIR/c/capi_dll_entry.cc"
HEADER_FILE="$LITERT_LM_DIR/c/engine.h"
SOURCE_FILE="$LITERT_LM_DIR/c/engine.cc"

# Backups — restored by cleanup()
BUILD_BACKUP="$BUILD_FILE.flutter_gemma_backup"
HEADER_BACKUP="$HEADER_FILE.flutter_gemma_backup"
SOURCE_BACKUP="$SOURCE_FILE.flutter_gemma_backup"

cp "$BUILD_FILE" "$BUILD_BACKUP"
cp "$HEADER_FILE" "$HEADER_BACKUP"
cp "$SOURCE_FILE" "$SOURCE_BACKUP"

# ============================================================================
# Patch engine.h: add litert_lm_engine_settings_set_dispatch_lib_dir
# ============================================================================
# The upstream C API is missing a setter for the LiteRT dispatch library
# directory. Without it, the GPU/WebGPU accelerator can't find its shared
# libraries (libLiteRtWebGpuAccelerator.so, etc.) and crashes during init.

if ! grep -q "litert_lm_engine_settings_set_dispatch_lib_dir" "$HEADER_FILE"; then
    sed -i.bak '/#ifdef __cplusplus/{
        i\
\
// Sets the LiteRT dispatch library directory. This tells the runtime where\
// to find accelerator shared libs (e.g. libLiteRtWebGpuAccelerator.so). If\
// not set, the runtime searches environment variables / system paths, which\
// may fail for bundled apps.\
//\
// @param settings The engine settings.\
// @param dir The directory containing LiteRT accelerator libraries.\
LITERT_LM_C_API_EXPORT\
void litert_lm_engine_settings_set_dispatch_lib_dir(\
    LiteRtLmEngineSettings* settings, const char* dir);\

    }' "$HEADER_FILE"
    rm -f "$HEADER_FILE.bak"
    echo "  Patched engine.h: added set_dispatch_lib_dir declaration"
fi

# ============================================================================
# Patch engine.cc: implement litert_lm_engine_settings_set_dispatch_lib_dir
# ============================================================================

if ! grep -q "litert_lm_engine_settings_set_dispatch_lib_dir" "$SOURCE_FILE"; then
    sed -i.bak '/^}  \/\/ extern "C"/i\
\
void litert_lm_engine_settings_set_dispatch_lib_dir(\
    LiteRtLmEngineSettings* settings, const char* dir) {\
  if (settings \&\& settings->settings \&\& dir) {\
    // Set on main executor — GPU/WebGPU accelerator loads from here\
    settings->settings->GetMutableMainExecutorSettings()\
        .SetLitertDispatchLibDir(dir);\
    // Also set on vision executor if it exists (returns std::optional)\
    auto vision = settings->settings->GetMutableVisionExecutorSettings();\
    if (vision.has_value()) {\
      vision->SetLitertDispatchLibDir(dir);\
    }\
  }\
}\
' "$SOURCE_FILE"
    rm -f "$SOURCE_FILE.bak"
    echo "  Patched engine.cc: added set_dispatch_lib_dir implementation"
fi

# ============================================================================
# Create linker stub — forces all C API symbols to survive dead-code stripping
# ============================================================================

cat > "$STUB_FILE" << 'EOF'
// =======================================================================
// LiteRT-LM C API shared library entry point.
// This stub forces the linker to include every exported C API symbol by
// taking their addresses into a volatile array. Without this, the linker
// can strip unreferenced symbols from the final shared library.
// =======================================================================

#include "engine.h"
#include <stddef.h>

// Force the linker to keep every C API symbol by referencing them.
// The volatile qualifier prevents the compiler from optimising this away.
volatile const void* litert_lm_force_exports[] = {
    (const void*)&litert_lm_set_min_log_level,
    (const void*)&litert_lm_engine_settings_create,
    (const void*)&litert_lm_engine_settings_delete,
    (const void*)&litert_lm_engine_settings_set_max_num_tokens,
    (const void*)&litert_lm_engine_settings_set_cache_dir,
    (const void*)&litert_lm_engine_settings_set_dispatch_lib_dir,
    (const void*)&litert_lm_engine_settings_set_activation_data_type,
    (const void*)&litert_lm_engine_settings_enable_benchmark,
    (const void*)&litert_lm_engine_create,
    (const void*)&litert_lm_engine_delete,
    (const void*)&litert_lm_engine_create_session,
    (const void*)&litert_lm_session_delete,
    (const void*)&litert_lm_session_generate_content,
    (const void*)&litert_lm_session_generate_content_stream,
    (const void*)&litert_lm_session_get_benchmark_info,
    (const void*)&litert_lm_session_config_create,
    (const void*)&litert_lm_session_config_set_max_output_tokens,
    (const void*)&litert_lm_session_config_set_sampler_params,
    (const void*)&litert_lm_session_config_delete,
    (const void*)&litert_lm_responses_delete,
    (const void*)&litert_lm_responses_get_num_candidates,
    (const void*)&litert_lm_responses_get_response_text_at,
    (const void*)&litert_lm_conversation_config_create,
    (const void*)&litert_lm_conversation_config_delete,
    (const void*)&litert_lm_conversation_create,
    (const void*)&litert_lm_conversation_delete,
    (const void*)&litert_lm_conversation_send_message,
    (const void*)&litert_lm_conversation_send_message_stream,
    (const void*)&litert_lm_conversation_cancel_process,
    (const void*)&litert_lm_conversation_get_benchmark_info,
    (const void*)&litert_lm_json_response_delete,
    (const void*)&litert_lm_json_response_get_string,
    (const void*)&litert_lm_benchmark_info_delete,
    (const void*)&litert_lm_benchmark_info_get_time_to_first_token,
    (const void*)&litert_lm_benchmark_info_get_num_prefill_turns,
    (const void*)&litert_lm_benchmark_info_get_num_decode_turns,
    (const void*)&litert_lm_benchmark_info_get_prefill_token_count_at,
    (const void*)&litert_lm_benchmark_info_get_decode_token_count_at,
    (const void*)&litert_lm_benchmark_info_get_prefill_tokens_per_sec_at,
    (const void*)&litert_lm_benchmark_info_get_decode_tokens_per_sec_at,
};
EOF

# ============================================================================
# Append Bazel build target
# ============================================================================
# The "engine_alwayslink" wrapper forces the linker to include ALL objects
# from the :engine cc_library. Combined with the explicit references in
# capi_dll_entry.cc, this guarantees all C API symbols are exported.

if [ "$BUILD_STATIC" = true ]; then
    # iOS: static library — no dynamic linking allowed on non-jailbroken iOS.
    # The .a gets linked into the Flutter iOS plugin framework by CocoaPods.
    cat >> "$BUILD_FILE" << 'EOF'

# ======================================================================
# flutter_gemma: Static library target for iOS
# (auto-generated by build_litert_lm_dll.sh — DO NOT COMMIT)
# ======================================================================
cc_library(
    name = "engine_alwayslink",
    deps = [":engine"],
    alwayslink = True,
)

cc_library(
    name = "litert_lm_capi_static",
    srcs = ["capi_dll_entry.cc"],
    deps = [":engine_alwayslink"],
    visibility = ["//visibility:public"],
)
EOF
    BAZEL_TARGET="//c:litert_lm_capi_static"
    echo "  Created cc_library target (static): $BAZEL_TARGET"
else
    # Desktop: shared library (.dylib / .so) loaded at runtime via Dart FFI
    cat >> "$BUILD_FILE" << 'EOF'

# ======================================================================
# flutter_gemma: Shared library target for Dart FFI
# (auto-generated by build_litert_lm_dll.sh — DO NOT COMMIT)
# ======================================================================
cc_library(
    name = "engine_alwayslink",
    deps = [":engine"],
    alwayslink = True,
)

cc_binary(
    name = "litert_lm_capi",
    srcs = ["capi_dll_entry.cc"],
    linkshared = True,
    deps = [":engine_alwayslink"],
    visibility = ["//visibility:public"],
)
EOF
    BAZEL_TARGET="//c:litert_lm_capi"
    echo "  Created cc_binary(linkshared=True) target: $BAZEL_TARGET"
fi

echo ""

# ============================================================================
# Cleanup on exit — restores all patched files, even on error
# ============================================================================

cleanup() {
    echo ""
    echo "Cleaning up temporary build files..."
    if [ -f "$BUILD_BACKUP" ]; then
        cp "$BUILD_BACKUP" "$BUILD_FILE"
        rm -f "$BUILD_BACKUP"
        echo "  Restored original c/BUILD"
    fi
    if [ -f "$HEADER_BACKUP" ]; then
        cp "$HEADER_BACKUP" "$HEADER_FILE"
        rm -f "$HEADER_BACKUP"
        echo "  Restored original c/engine.h"
    fi
    if [ -f "$SOURCE_BACKUP" ]; then
        cp "$SOURCE_BACKUP" "$SOURCE_FILE"
        rm -f "$SOURCE_BACKUP"
        echo "  Restored original c/engine.cc"
    fi
    if [ -f "$STUB_FILE" ]; then
        rm -f "$STUB_FILE"
        echo "  Removed capi_dll_entry.cc"
    fi
}
trap cleanup EXIT

# ============================================================================
# Build with Bazel
# ============================================================================

echo "Building LiteRT-LM C API library..."
echo "  First build downloads deps + compiles everything (~5-15 min)"
echo "  Subsequent builds are near-instant (Bazel caches everything)"
echo ""

cd "$LITERT_LM_DIR"

# shellcheck disable=SC2086
$BAZEL build $BAZEL_TARGET $BAZEL_EXTRA

echo ""
echo "Build succeeded!"

# ============================================================================
# Copy output to prebuilt directory
# ============================================================================

echo ""
echo "Copying build output..."

if [ "$BUILD_STATIC" = true ]; then
    # -----------------------------------------------------------------------
    # iOS static library — Bazel outputs a .a archive
    # -----------------------------------------------------------------------
    LIB_PATH=""
    for candidate in \
        "$LITERT_LM_DIR/bazel-bin/c/liblitert_lm_capi_static.a" \
        "$LITERT_LM_DIR/bazel-bin/c/litert_lm_capi_static.a"; do
        if [ -f "$candidate" ]; then
            LIB_PATH="$candidate"
            break
        fi
    done

    if [ -n "$LIB_PATH" ]; then
        OUT_NAME="liblitert_lm_capi.a"
        cp "$LIB_PATH" "$OUTPUT_DIR/$OUT_NAME"
        size=$(du -h "$OUTPUT_DIR/$OUT_NAME" | cut -f1)
        echo "  $OUT_NAME ($size)"
    else
        echo "  WARNING: Static library not found in bazel-bin/c/" >&2
        ls -la "$LITERT_LM_DIR/bazel-bin/c/" 2>/dev/null || true
    fi
else
    # -----------------------------------------------------------------------
    # Desktop shared library (.dylib / .so)
    # -----------------------------------------------------------------------
    LIB_PATH=""
    for candidate in \
        "$LITERT_LM_DIR/bazel-bin/c/litert_lm_capi.$LIB_EXT" \
        "$LITERT_LM_DIR/bazel-bin/c/liblitert_lm_capi.$LIB_EXT" \
        "$LITERT_LM_DIR/bazel-bin/c/litert_lm_capi"; do
        if [ -f "$candidate" ]; then
            LIB_PATH="$candidate"
            break
        fi
    done

    if [ -n "$LIB_PATH" ]; then
        if [ "$OS" = "Darwin" ]; then
            OUT_NAME="liblitert_lm_capi.dylib"
        else
            OUT_NAME="liblitert_lm_capi.so"
        fi

        cp "$LIB_PATH" "$OUTPUT_DIR/$OUT_NAME"
        size=$(du -h "$OUTPUT_DIR/$OUT_NAME" | cut -f1)
        echo "  $OUT_NAME ($size)"

        # Ad-hoc codesign on macOS so Gatekeeper doesn't reject it
        if [ "$OS" = "Darwin" ]; then
            codesign --force --sign - "$OUTPUT_DIR/$OUT_NAME" 2>/dev/null || true
            echo "  Signed: $OUT_NAME"
        fi
    else
        echo "  WARNING: Shared library not found in bazel-bin/c/" >&2
        ls -la "$LITERT_LM_DIR/bazel-bin/c/" 2>/dev/null || true
    fi
fi

# ============================================================================
# Copy prebuilt accelerator libraries (GPU/WebGPU — desktop only)
# ============================================================================
# These are separate .dylib/.so files shipped by Google in the LiteRT-LM repo
# under prebuilt/<arch>/. iOS doesn't use these (Metal is handled differently).

if [ "$BUILD_STATIC" = false ]; then
    PREBUILT_DIR="$LITERT_LM_DIR/prebuilt/$NATIVE_ARCH"
    if [ -d "$PREBUILT_DIR" ]; then
        for lib in "$PREBUILT_DIR"/*."$LIB_EXT" "$PREBUILT_DIR"/*.so; do
            [ -f "$lib" ] || continue
            filename=$(basename "$lib")
            cp "$lib" "$OUTPUT_DIR/$filename"
            echo "  $filename (accelerator)"
            if [ "$OS" = "Darwin" ]; then
                codesign --force --sign - "$OUTPUT_DIR/$filename" 2>/dev/null || true
            fi
        done
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "Output: $OUTPUT_DIR"
for f in "$OUTPUT_DIR"/*; do
    [ -f "$f" ] || continue
    size=$(du -h "$f" | cut -f1)
    echo "  $(basename "$f") ($size)"
done
echo ""

if [ "$BUILD_STATIC" = true ]; then
    echo "Static library ready. CocoaPods will link it into the Flutter iOS plugin."
else
    echo "Shared library ready. Flutter's build system will bundle it automatically."
    echo "Run 'flutter build' to verify."
fi
