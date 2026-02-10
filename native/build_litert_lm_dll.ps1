<#
.SYNOPSIS
    One-time build script: compiles LiteRT-LM C API into a shared library (DLL)

.DESCRIPTION
    Uses Bazel to build the LiteRT-LM C API as a shared library from source.
    Run this ONCE, then Flutter's build system will bundle the resulting DLL.

    Prerequisites (you should have these already):
      - Bazel / Bazelisk 7.6.1+
      - MSVC (Visual Studio Build Tools)
      - Python 3.x
      - Git

    Output goes to: native/prebuilt/windows_x86_64/

.PARAMETER LiteRtLmDir
    Path to the LiteRT-LM source checkout. Defaults to ..\LiteRT-LM-ref

.EXAMPLE
    .\build_litert_lm_dll.ps1
    .\build_litert_lm_dll.ps1 -LiteRtLmDir "C:\Projects\LiteRT-LM"
#>

param(
    [string]$LiteRtLmDir = ""
)

# Note: we do NOT use $ErrorActionPreference = "Stop" globally because
# Bazel/bazelisk writes download progress and warnings to stderr, which
# PowerShell would incorrectly treat as terminating errors.

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LiteRT-LM C API DLL Builder (Windows)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Resolve paths
# ============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = Split-Path -Parent $ScriptDir

# Find LiteRT-LM source directory
if ([string]::IsNullOrEmpty($LiteRtLmDir)) {
    # Check common locations relative to plugin
    $candidates = @(
        "$PluginRoot\..\LiteRT-LM-ref",
        "$PluginRoot\..\LiteRT-LM",
        "$env:USERPROFILE\LiteRT-LM"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\c\engine.h") {
            $LiteRtLmDir = (Resolve-Path $c).Path
            break
        }
    }
}

if ([string]::IsNullOrEmpty($LiteRtLmDir) -or -not (Test-Path "$LiteRtLmDir\c\engine.h")) {
    Write-Host "ERROR: LiteRT-LM source not found." -ForegroundColor Red
    Write-Host "Pass -LiteRtLmDir or clone to ..\LiteRT-LM-ref" -ForegroundColor Yellow
    Write-Host "  git clone https://github.com/google-ai-edge/LiteRT-LM.git ..\LiteRT-LM-ref" -ForegroundColor Gray
    exit 1
}

# Output directory for built libraries
$OutputDir = "$ScriptDir\prebuilt\windows_x86_64"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "LiteRT-LM source: $LiteRtLmDir"
Write-Host "Output dir:       $OutputDir"
Write-Host ""

# ============================================================================
# Verify tools
# ============================================================================

Write-Host "Checking build tools..." -ForegroundColor Gray

# Check bazelisk/bazel - search PATH and common install locations
$bazel = $null
$bazelSearchPaths = @(
    "$env:APPDATA\npm\bazelisk.cmd",
    "$env:APPDATA\npm\bazel.cmd",
    "$env:LOCALAPPDATA\Programs\bazel\bazel.exe",
    "$env:USERPROFILE\bin\bazelisk.exe",
    "$env:USERPROFILE\bin\bazel.exe"
)

# First check PATH via Get-Command
foreach ($cmd in @("bazelisk", "bazel")) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        $bazel = $found.Source
        break
    }
}

# Then check known install locations
if (-not $bazel) {
    foreach ($path in $bazelSearchPaths) {
        if (Test-Path $path) {
            $bazel = $path
            break
        }
    }
}

if (-not $bazel) {
    Write-Host "ERROR: bazelisk or bazel not found" -ForegroundColor Red
    Write-Host "  Checked: PATH, npm global, common install locations" -ForegroundColor Gray
    exit 1
}
Write-Host "  Bazel: $bazel" -ForegroundColor Green

# Check MSVC
$clExe = Get-Command "cl.exe" -ErrorAction SilentlyContinue
if (-not $clExe) {
    Write-Host "  MSVC cl.exe not in PATH - trying to find via vswhere..." -ForegroundColor Yellow
    # Try to activate MSVC
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -property installationPath 2>$null
        if ($vsPath) {
            $vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $vcvars) {
                Write-Host "  Found MSVC at: $vsPath" -ForegroundColor Green
                Write-Host "  NOTE: Run this script from a 'Developer Command Prompt' or 'x64 Native Tools'" -ForegroundColor Yellow
            }
        }
    }
}
else {
    Write-Host "  MSVC: $($clExe.Source)" -ForegroundColor Green
}

Write-Host ""

# ============================================================================
# Create temporary shared library target in the LiteRT-LM c/ directory
# ============================================================================

Write-Host "Setting up build target..." -ForegroundColor Gray

$BuildFile = "$LiteRtLmDir\c\BUILD"
$StubFile = "$LiteRtLmDir\c\capi_dll_entry.cc"
$BuildBackup = "$BuildFile.flutter_gemma_backup"

# Strip any leftover flutter_gemma targets from previous failed runs before backup
$buildContent = Get-Content -Path $BuildFile -Raw
$marker = "# Flutter Gemma: Shared library target for Dart FFI"
if ($buildContent -match [regex]::Escape($marker)) {
    Write-Host "  Cleaning leftover flutter_gemma targets from c/BUILD..." -ForegroundColor Yellow
    # Remove everything from the first marker to end of file
    $idx = $buildContent.IndexOf("# ======================================================================`n# Flutter Gemma")
    if ($idx -lt 0) { $idx = $buildContent.IndexOf($marker) - 80 }  # rough fallback
    if ($idx -gt 0) {
        $buildContent = $buildContent.Substring(0, $idx).TrimEnd() + "`n"
        Set-Content -Path $BuildFile -Value $buildContent -Encoding UTF8 -NoNewline
    }
}

# Backup original (clean) BUILD file
Copy-Item -Path $BuildFile -Destination $BuildBackup -Force

# Create stub source file that explicitly references every C API function.
# This is the nuclear option: even if alwayslink is defeated by Bazel flags
# (--legacy_whole_archive=0, /OPT:REF, etc.), the linker MUST keep these
# symbols because they are directly referenced from this translation unit.
@"
// =======================================================================
// LiteRT-LM C API shared library entry point.
// This stub forces the linker to include every exported C API symbol by
// taking their addresses into a volatile array. Without this, MSVC's
// /OPT:REF + Bazel's --legacy_whole_archive=0 can strip engine.obj
// from the final DLL even with alwayslink = True.
// =======================================================================

#include "engine.h"
#include <stddef.h>

#ifdef _WIN32
#include <windows.h>
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    (void)hModule; (void)reason; (void)lpReserved;
    return TRUE;
}
#endif

// Force the linker to keep every C API symbol by referencing them.
// The volatile qualifier prevents the compiler from optimising this away.
volatile const void* litert_lm_force_exports[] = {
    (const void*)&litert_lm_set_min_log_level,
    (const void*)&litert_lm_engine_settings_create,
    (const void*)&litert_lm_engine_settings_delete,
    (const void*)&litert_lm_engine_settings_set_max_num_tokens,
    (const void*)&litert_lm_engine_settings_set_cache_dir,
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
"@ | Set-Content -Path $StubFile -Encoding UTF8

# Append shared library target to BUILD file.
# The "engine_alwayslink" wrapper forces the linker to include ALL objects
# from the :engine cc_library. Combined with the explicit references in
# capi_dll_entry.cc above, this guarantees all C API symbols are exported.
@"

# ======================================================================
# Flutter Gemma: Shared library target for Dart FFI
# (auto-generated by build_litert_lm_dll.ps1 - DO NOT COMMIT)
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
"@ | Add-Content -Path $BuildFile -Encoding UTF8

Write-Host "  Created cc_binary(linkshared=True) target: //c:litert_lm_capi" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Build with Bazel
# ============================================================================

try {
    Write-Host "Building LiteRT-LM C API DLL..." -ForegroundColor Cyan
    Write-Host "  This may take a while on first build (downloads deps, compiles everything)" -ForegroundColor Gray
    Write-Host ""

    Push-Location $LiteRtLmDir

    # Ensure Bazel uses Git Bash (not WSL) for shell commands like sed/patch.
    # Without this, repository patch_cmds fail with "WSL2 is not supported".
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (Test-Path $gitBash) {
        $env:BAZEL_SH = $gitBash
        Write-Host "  BAZEL_SH=$gitBash" -ForegroundColor DarkGray
    } else {
        Write-Host "  WARNING: Git Bash not found at $gitBash" -ForegroundColor Yellow
    }

    # Point Bazel to the correct Visual C++ installation to avoid auto-detection issues.
    if (-not $env:BAZEL_VC) {
        $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vsWhere) {
            $vsPath = & $vsWhere -latest -property installationPath 2>$null
            if ($vsPath -and (Test-Path "$vsPath\VC")) {
                $env:BAZEL_VC = "$vsPath\VC"
                Write-Host "  BAZEL_VC=$($env:BAZEL_VC)" -ForegroundColor DarkGray
            }
        }
    }

    # Run the Bazel build.
    # Use $ErrorActionPreference = "Continue" locally so stderr from
    # bazelisk/bazel (download progress, build status) is not fatal.
    Write-Host "  > $bazel build //c:litert_lm_capi --config=windows" -ForegroundColor DarkGray
    Write-Host ""

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # Use a short output_user_root to avoid Windows 260-char path limit
    # (Rust proc-macro intermediate files have extremely long names)
    & $bazel --output_user_root=C:/b build //c:litert_lm_capi --config=windows 2>&1 | ForEach-Object {
        Write-Host "  $_"
    }
    $buildExitCode = $LASTEXITCODE

    $ErrorActionPreference = $prevEAP

    if ($buildExitCode -ne 0) {
        throw "Bazel build failed with exit code $buildExitCode"
    }

    Pop-Location

    Write-Host ""
    Write-Host "Build succeeded!" -ForegroundColor Green

    # ============================================================================
    # Copy output DLL to our prebuilt directory
    # ============================================================================

    Write-Host ""
    Write-Host "Copying build output..." -ForegroundColor Gray

    # The DLL is at bazel-bin/c/litert_lm_capi.dll
    $dllPath = "$LiteRtLmDir\bazel-bin\c\litert_lm_capi.dll"
    if (-not (Test-Path $dllPath)) {
        # Bazel might name it differently - check for alternatives
        $alternatives = @(
            "$LiteRtLmDir\bazel-bin\c\litert_lm_capi.dll",
            "$LiteRtLmDir\bazel-bin\c\litert_lm_capi.so",
            "$LiteRtLmDir\bazel-bin\c\liblitert_lm_capi.dll"
        )
        foreach ($alt in $alternatives) {
            if (Test-Path $alt) {
                $dllPath = $alt
                break
            }
        }
    }

    if (Test-Path $dllPath) {
        Copy-Item -Path $dllPath -Destination "$OutputDir\litert_lm_capi.dll" -Force
        $size = [math]::Round((Get-Item $dllPath).Length / 1MB, 1)
        Write-Host "  Copied: litert_lm_capi.dll ($size MB)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: DLL not found at expected path: $dllPath" -ForegroundColor Yellow
        Write-Host "  Checking bazel-bin/c/ for any shared libraries..." -ForegroundColor Gray
        Get-ChildItem "$LiteRtLmDir\bazel-bin\c" -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    Found: $($_.Name)" -ForegroundColor Yellow
        }
    }

    # Copy prebuilt accelerator DLLs too
    $prebuiltDir = "$LiteRtLmDir\prebuilt\windows_x86_64"
    if (Test-Path $prebuiltDir) {
        Get-ChildItem -Path $prebuiltDir -Filter "*.dll" | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination "$OutputDir\$($_.Name)" -Force
            Write-Host "  Copied: $($_.Name) (accelerator)" -ForegroundColor Green
        }
    }

} finally {
    # ============================================================================
    # Clean up - restore original BUILD file and remove stub
    # ============================================================================

    Write-Host ""
    Write-Host "Cleaning up temporary build files..." -ForegroundColor Gray

    if (Test-Path $BuildBackup) {
        Copy-Item -Path $BuildBackup -Destination $BuildFile -Force
        Remove-Item -Path $BuildBackup -Force
        Write-Host "  Restored original c/BUILD" -ForegroundColor Green
    }
    if (Test-Path $StubFile) {
        Remove-Item -Path $StubFile -Force
        Write-Host "  Removed capi_dll_entry.cc" -ForegroundColor Green
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Build complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output directory: $OutputDir" -ForegroundColor White
Write-Host ""
Write-Host "Contents:" -ForegroundColor Gray
Get-ChildItem -Path $OutputDir -Filter "*.dll" | ForEach-Object {
    $size = [math]::Round($_.Length / 1MB, 1)
    Write-Host "  $($_.Name) ($size MB)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Next: run 'flutter build windows' - the plugin will bundle these automatically." -ForegroundColor Cyan
