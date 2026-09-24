# Build patched projectM 4 for Windows into vendor/projectm4 (mirrors
# setup-vendor.sh). projectM's deps (glew, glm) come from vcpkg via the
# toolchain file. Run from CI with VCPKG_ROOT set.
param(
  [string]$Prefix = "$PSScriptRoot/../vendor/projectm4"
)
$ErrorActionPreference = "Stop"
$Root = Resolve-Path "$PSScriptRoot/.."
$Vendor = "$Root/vendor"
$Src = "$Vendor/projectm-src"
$PmVer = "v4.1.6"

if (Test-Path "$Prefix/lib/cmake/projectM4/projectM4Config.cmake") {
  Write-Host "projectM already built at $Prefix — skipping."
  exit 0
}

New-Item -ItemType Directory -Force -Path $Vendor | Out-Null
if (-not (Test-Path $Src)) {
  git clone --recursive --depth 1 --branch $PmVer `
    https://github.com/projectM-visualizer/projectm.git $Src
}

Push-Location $Src
# caller-bound FBO patch — required for QQuickFramebufferObject embedding
& git apply --check "$Root/patches/projectm-caller-fbo.patch" 2>$null
if ($LASTEXITCODE -eq 0) {
  & git apply "$Root/patches/projectm-caller-fbo.patch"
  Write-Host "applied projectm-caller-fbo.patch"
} else {
  Write-Host "patch already applied (or --check failed); continuing"
}
Pop-Location

cmake -S $Src -B "$Src/build" `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_INSTALL_PREFIX="$Prefix" `
  -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
  -DENABLE_PLAYLIST=ON -DBUILD_TESTING=OFF
cmake --build "$Src/build" --config Release
cmake --install "$Src/build" --config Release
Write-Host "projectM $PmVer ready at $Prefix"
