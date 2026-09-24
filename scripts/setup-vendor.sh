#!/bin/bash
# One-time vendor setup: build patched projectM 4 into vendor/projectm4.
# Requires: cmake, g++, git. See README for the full dependency list.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
PM_VER="v4.1.7"

STATIC=OFF
[ "${1:-}" = "--static" ] && STATIC=ON

if [ -f "$VENDOR/projectm4/lib64/pkgconfig/projectM-4.pc" ]; then
    echo "projectM already built at vendor/projectm4 — delete it to rebuild."
    exit 0
fi

mkdir -p "$VENDOR"
cd "$VENDOR"

if [ ! -d projectm-src ]; then
    git clone --recursive --depth 1 --branch "$PM_VER" \
        https://github.com/projectM-visualizer/projectm.git projectm-src
fi

cd projectm-src

# Output to the caller-bound framebuffer instead of hardcoded 0 — REQUIRED for
# QQuickFramebufferObject embedding (and QOpenGLWidget). Upstream ToDo.
if git apply --check "$ROOT/patches/projectm-caller-fbo.patch" 2>/dev/null; then
    git apply "$ROOT/patches/projectm-caller-fbo.patch"
    echo "applied projectm-caller-fbo.patch"
else
    echo "patch did not apply cleanly — checking whether it is already in"
fi

# A failed --check means either "already applied" or "will not apply", so check
# for the patched code. An unpatched projectM renders to framebuffer 0 instead
# of the caller's, so a host whose default framebuffer is an FBO gets a black
# visualiser with no error anywhere.
if ! grep -q callerDrawFbo src/libprojectM/ProjectM.cpp; then
    echo "FATAL: projectm-caller-fbo.patch is NOT in ProjectM.cpp." >&2
    echo "  The visualiser renders black without it. Refusing to build a" >&2
    echo "  projectM that cannot draw into a caller-bound FBO." >&2
    exit 1
fi

cmake -S . -B build -G "Unix Makefiles" \
    -DBUILD_SHARED_LIBS=$([ "$STATIC" = ON ] && echo OFF || echo ON) \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$STATIC \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_INSTALL_PREFIX="$VENDOR/projectm4" \
    -DENABLE_PLAYLIST=ON -DBUILD_TESTING=OFF
cmake --build build -j"$(nproc)"
cmake --install build

# projectM's generated .pc files use broken `-l:name` syntax — fix to `-lname`.
sed -i 's/-l:projectM-4-playlist/-lprojectM-4-playlist/; s/-l:projectM-4/-lprojectM-4/' \
    "$VENDOR/projectm4"/lib*/pkgconfig/projectM-4*.pc

echo "projectM $PM_VER ready at vendor/projectm4"
