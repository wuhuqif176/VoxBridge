# Build libdf.a (DeepFilterNet3 C API static lib) for HarmonyOS arm64.
# Prereqs: rustup with aarch64-unknown-linux-ohos target, OHOS SDK (API 26).
# Usage:
#   powershell -File tools/build_libdf.ps1 -DfRepo <path-to-DeepFilterNet> -OhosSdkNative <path-to-ohos-sdk-native>
#   (or set env vars DF_REPO / OHOS_SDK_NATIVE; a prebuilt libdf.a ships with this repo,
#    so rebuilding is only needed when you want a newer DeepFilterNet version)
param(
    [string]$DfRepo = $(if ($env:DF_REPO) { $env:DF_REPO } else { Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "third_party\DeepFilterNet" }),
    [string]$OhosSdkNative = $(if ($env:OHOS_SDK_NATIVE) { $env:OHOS_SDK_NATIVE } else { Join-Path $env:DEVECO_HOME "sdk\default\openharmony\native" })
)
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot          # repo root
$cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"
$sdkNativeShort = ($OhosSdkNative -replace '\\', '/')
$outDir = Join-Path $repoRoot "entry\libs\arm64-v8a"

if (-not (Test-Path $DfRepo)) {
    git clone --depth 1 --branch v0.5.6 https://github.com/Rikorose/DeepFilterNet.git $DfRepo
    # Then apply the patch tools/libdf-harmonymic.patch to libDF/src/capi.rs:
    #   DFState::new: empty model_path -> DfParams::default() (embedded DFN3 model)
    #   df_create:    NULL path -> empty string
    throw "DeepFilterNet clone missing or unpatched. Clone v0.5.6 and patch libDF/src/capi.rs first."
}

# time 0.3.28 does not compile on rustc >= 1.80; bump once (idempotent)
& $cargo update -p time --precise 0.3.36 --manifest-path (Join-Path $DfRepo "Cargo.toml")

$env:CC_aarch64_unknown_linux_ohos   = "$sdkNativeShort/llvm/bin/clang.exe"
$env:CXX_aarch64_unknown_linux_ohos  = "$sdkNativeShort/llvm/bin/clang++.exe"
$env:CFLAGS_aarch64_unknown_linux_ohos = "--target=aarch64-unknown-linux-ohos --sysroot=$sdkNativeShort/sysroot"

& $cargo rustc -p deep_filter --release --no-default-features --features capi `
    --crate-type staticlib --target aarch64-unknown-linux-ohos `
    --manifest-path (Join-Path $DfRepo "Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item (Join-Path $DfRepo "target\aarch64-unknown-linux-ohos\release\libdf.a") `
    (Join-Path $outDir "libdf.a") -Force
Write-Host "libdf.a -> $outDir"
