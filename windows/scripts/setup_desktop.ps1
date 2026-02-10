<#
.SYNOPSIS
    LiteRT-LM Native Desktop Setup Script for Flutter Gemma (Windows)

.DESCRIPTION
    Downloads prebuilt LiteRT-LM accelerator libraries from GitHub and
    DirectX Shader Compiler for Windows GPU support.
    No Java, no JRE, no JAR — pure native.

.PARAMETER PluginDir
    Path to the plugin directory (flutter_gemma/windows)

.PARAMETER OutputDir
    Path to the CMake build output directory

.EXAMPLE
    .\setup_desktop.ps1 -PluginDir "C:\flutter_gemma\windows" -OutputDir "C:\build"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$PluginDir,

    [Parameter(Mandatory=$true)]
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

Write-Host "=== LiteRT-LM Native Desktop Setup (Windows) ===" -ForegroundColor Cyan

# ============================================================================
# Configuration
# ============================================================================

# GitHub base URL for prebuilt C API + accelerator DLLs.
# These are built from LiteRT-LM source with the custom C API wrapper.
# See: https://github.com/Kemerd/LiteRT-LM-FFI
$GitHubBaseUrl = "https://github.com/Kemerd/LiteRT-LM-FFI/raw/master/prebuilt"

# Architecture detection
$Arch = $env:PROCESSOR_ARCHITECTURE
if ($Arch -eq "ARM64") {
    Write-Host "ERROR: ARM64 Windows is not supported by LiteRT-LM" -ForegroundColor Red
    Write-Host "Only x86_64 is supported." -ForegroundColor Yellow
    exit 1
}

$NativeArch = "windows_x86_64"
Write-Host "Architecture: x64"
Write-Host "Plugin dir: $PluginDir"
Write-Host "Output dir: $OutputDir"

$PluginRoot = Split-Path -Parent $PluginDir

# Libraries we need for Windows:
#   - litert_lm_capi.dll  — the main C API library (built from source via native/build_litert_lm_dll.ps1)
#   - Accelerator DLLs    — from LiteRT-LM/prebuilt/windows_x86_64/
$PrebuiltLibs = @(
    "litert_lm_capi.dll",
    "libGemmaModelConstraintProvider.dll",
    "libLiteRt.dll",
    "libLiteRtTopKWebGpuSampler.dll",
    "libLiteRtWebGpuAccelerator.dll"
)

# Local cache so we don't re-download every build
$CacheDir = "$env:LOCALAPPDATA\flutter_gemma\prebuilt\$NativeArch"

# Output directory for bundled natives
$NativesDir = "$OutputDir\litertlm"
New-Item -ItemType Directory -Force -Path $NativesDir | Out-Null
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# ============================================================================
# Helper: download a file if not cached
# ============================================================================
function Download-IfNotCached {
    param(
        [string]$FileName,
        [string]$DestDir
    )

    $cachedFile = "$CacheDir\$FileName"
    $destFile   = "$DestDir\$FileName"

    # Already in output? Skip entirely.
    if (Test-Path $destFile) {
        Write-Host "  [cached] $FileName" -ForegroundColor DarkGray
        return
    }

    # Check local cache first
    if (Test-Path $cachedFile) {
        Copy-Item -Path $cachedFile -Destination $destFile -Force
        Write-Host "  [cache]  $FileName" -ForegroundColor Green
        return
    }

    # Check local dev paths:
    #   1. native/prebuilt/ (built by native/build_litert_lm_dll.ps1)
    #   2. LiteRT-LM-ref/prebuilt/ (cloned repo)
    $localPaths = @(
        "$PluginRoot\native\prebuilt\$NativeArch\$FileName",
        "$PluginRoot\..\LiteRT-LM-ref\prebuilt\$NativeArch\$FileName"
    )
    foreach ($localPath in $localPaths) {
        if (Test-Path $localPath) {
            Copy-Item -Path $localPath -Destination $destFile -Force
            Copy-Item -Path $localPath -Destination $cachedFile -Force
            Write-Host "  [local]  $FileName" -ForegroundColor Green
            return
        }
    }

    # Download from GitHub (raw URL handles LFS redirect)
    # Note: litert_lm_capi.dll is NOT on GitHub — it must be built locally
    $url = "$GitHubBaseUrl/$NativeArch/$FileName"
    Write-Host "  [download] $FileName from GitHub..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        Invoke-WebRequest -Uri $url -OutFile $cachedFile -UseBasicParsing
        Copy-Item -Path $cachedFile -Destination $destFile -Force
        Write-Host "  [ok]     $FileName" -ForegroundColor Green
    } catch {
        # Not fatal for the main CAPI library — it must be built from source
        if ($FileName -eq "litert_lm_capi.dll") {
            Write-Host "  [MISSING] $FileName — run native\build_litert_lm_dll.ps1 to build from source" -ForegroundColor Red
        } else {
            Write-Warning "  Failed to download $FileName : $_"
            Write-Host "  URL: $url" -ForegroundColor Gray
        }
    }
}

# ============================================================================
# Install prebuilt accelerator libraries
# ============================================================================
function Install-PrebuiltLibs {
    Write-Host ""
    Write-Host "=== Installing prebuilt LiteRT-LM libraries ===" -ForegroundColor White

    foreach ($lib in $PrebuiltLibs) {
        Download-IfNotCached -FileName $lib -DestDir $NativesDir
    }
}

# ============================================================================
# Download DirectX Shader Compiler (required for GPU on Windows)
# ============================================================================
function Install-DXC {
    Write-Host ""
    Write-Host "=== Installing DirectX Shader Compiler ===" -ForegroundColor White

    $dxilDll = "$NativesDir\dxil.dll"
    $dxcompilerDll = "$NativesDir\dxcompiler.dll"

    # Skip if already present
    if ((Test-Path $dxilDll) -and (Test-Path $dxcompilerDll)) {
        Write-Host "  DirectX Shader Compiler already installed" -ForegroundColor Green
        return
    }

    # DXC release info (required for WebGPU backend on Windows)
    $dxcVersion = "v1.7.2308"
    $dxcUrl = "https://github.com/microsoft/DirectXShaderCompiler/releases/download/$dxcVersion/dxc_2023_08_14.zip"
    $dxcCacheDir = "$env:LOCALAPPDATA\flutter_gemma\dxc"
    $dxcArchive = "$dxcCacheDir\dxc_$dxcVersion.zip"

    New-Item -ItemType Directory -Force -Path $dxcCacheDir | Out-Null

    # Download DXC archive if not cached
    if (-not (Test-Path $dxcArchive)) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            Write-Host "  Downloading DXC $dxcVersion..."
            Invoke-WebRequest -Uri $dxcUrl -OutFile $dxcArchive -UseBasicParsing
        } catch {
            Write-Warning "  Failed to download DXC: $_"
            Write-Host "  GPU may not work without DirectX Shader Compiler" -ForegroundColor Yellow
            return
        }
    } else {
        Write-Host "  Using cached DXC archive" -ForegroundColor Green
    }

    # Extract and copy the DLLs we need
    try {
        $extractDir = "$dxcCacheDir\extracted"
        if (-not (Test-Path "$extractDir\bin\x64\dxil.dll")) {
            Write-Host "  Extracting DXC..."
            Expand-Archive -Path $dxcArchive -DestinationPath $extractDir -Force
        }

        Copy-Item -Path "$extractDir\bin\x64\dxil.dll" -Destination $dxilDll -Force
        Copy-Item -Path "$extractDir\bin\x64\dxcompiler.dll" -Destination $dxcompilerDll -Force

        Write-Host "  DirectX Shader Compiler installed" -ForegroundColor Green
    } catch {
        Write-Warning "  Failed to extract DXC: $_"
    }
}

# ============================================================================
# Main
# ============================================================================
try {
    Install-PrebuiltLibs
    Install-DXC

    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "=== Setup complete ===" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Natives dir: $NativesDir"
    Write-Host ""

    # List what we have
    Write-Host "Bundled libraries:" -ForegroundColor Gray
    Get-ChildItem -Path $NativesDir -Filter "*.dll" | ForEach-Object {
        Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" -ForegroundColor Gray
    }
} catch {
    Write-Host "SETUP FAILED: $_" -ForegroundColor Red
    exit 1
}
