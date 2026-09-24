#!/usr/bin/env bash
# One tar of corresponding source for every LGPL/GPL component the Linux builds
# ship, attached beside the binaries. Qt and projectM are static and patched;
# FFmpeg ships as a program; the lite AppImage's runtime links libfuse
# statically; the full AppImage carries Ubuntu's shared libraries.
#
#   scripts/release-sources.sh <AppDir> <out.tar>
#
# Needs deb-src enabled for `apt-get source`; versions the mirror dropped come
# from Launchpad (pull-lp-source, ubuntu-dev-tools). Libraries no Ubuntu package
# owns are listed in UNRESOLVED.txt inside the tar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="${1:?usage: $0 <AppDir> <out.tar>}"
OUT="$(realpath -m "${2:?usage: $0 <AppDir> <out.tar>}")"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
S="$W/melo-sources"
mkdir -p "$S/qt" "$S/projectm" "$S/ffmpeg" "$S/ubuntu"

# --- Qt: the modules the static build compiles, and melo's patch ------------
QT=6.11.2
QTBASE="https://download.qt.io/archive/qt/6.11/$QT/submodules"
for m in qtbase qtshadertools qtdeclarative qtwayland qtimageformats qt5compat; do
    curl -fsSLo "$S/qt/$m-everywhere-src-$QT.tar.xz" "$QTBASE/$m-everywhere-src-$QT.tar.xz"
done
cp "$ROOT/patches/qtdeclarative-$QT-stacking-walk.patch" "$S/qt/"

# --- projectM: the tag setup-vendor.sh pins, with submodules, and the patch --
PM="$(sed -n 's/^PM_VER="\(.*\)"$/\1/p' "$ROOT/scripts/setup-vendor.sh")"
git clone -q --recursive --depth 1 --branch "$PM" \
    https://github.com/projectM-visualizer/projectm.git "$W/projectm-$PM"
tar -C "$W" --exclude=.git -czf "$S/projectm/projectm-$PM.tar.gz" "projectm-$PM"
cp "$ROOT/patches/projectm-caller-fbo.patch" "$S/projectm/"

# --- FFmpeg: the tarball build-ffmpeg.sh pins, checked against its hash ------
FV="$(sed -n 's/^VER="\(.*\)"$/\1/p' "$ROOT/scripts/build-ffmpeg.sh")"
FSHA="$(sed -n 's/^SHA256="\(.*\)"$/\1/p' "$ROOT/scripts/build-ffmpeg.sh")"
curl -fsSLo "$S/ffmpeg/ffmpeg-$FV.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FV.tar.xz"
echo "$FSHA  $S/ffmpeg/ffmpeg-$FV.tar.xz" | sha256sum -c --quiet
cp "$ROOT/scripts/build-ffmpeg.sh" "$S/ffmpeg/"   # holds the configure line

# --- the lite AppImage's runtime, and the libraries it links statically -----
RT=20251108
mkdir -p "$S/appimage-runtime"
curl -fsSLo "$S/appimage-runtime/type2-runtime-$RT.tar.gz" \
    "https://github.com/AppImage/type2-runtime/archive/refs/tags/$RT.tar.gz"
curl -fsSLo "$S/appimage-runtime/fuse-3.15.0.tar.xz" \
    https://github.com/libfuse/libfuse/releases/download/fuse-3.15.0/fuse-3.15.0.tar.xz
curl -fsSLo "$S/appimage-runtime/squashfuse-0.5.2.tar.gz" \
    https://github.com/vasi/squashfuse/archive/0.5.2.tar.gz
( cd "$S/appimage-runtime" && sha256sum -c --quiet ) <<'SUMS'
70589cfd5e1cff7ccd6ac91c86c01be340b227285c5e200baa284e401eea2ca0  fuse-3.15.0.tar.xz
db0238c5981dabbd80ee09ae15387f390091668ca060a7bc38047912491443d3  squashfuse-0.5.2.tar.gz
SUMS

# --- Ubuntu: the source package of every shared library the AppDir carries --
: > "$S/UNRESOLVED.txt"
if [ -d "$APPDIR/usr/lib" ]; then
    find "$APPDIR/usr/lib" -type f -name '*.so*' -printf '%f\n' | sort -u |
    while read -r lib; do
        owner="$(dpkg -S "*/$lib" 2>/dev/null | head -1 | cut -d: -f1 || true)"
        if [ -z "$owner" ]; then echo "$lib" >> "$S/UNRESOLVED.txt"; continue; fi
        dpkg-query -W -f='${source:Package}=${source:Version}\n' "$owner"
    done | sort -u > "$W/srcpkgs.txt"
    # The mirror keeps only the newest source of each package, and the runner
    # image can ship an older binary. Launchpad keeps every version, so the
    # exact one shipped is fetched from there when the mirror has moved on.
    while IFS='=' read -r pkg ver; do
        [ -n "$pkg" ] || continue
        ( cd "$S/ubuntu" && apt-get source --download-only -qq "$pkg=$ver" ) \
            || ( cd "$S/ubuntu" && pull-lp-source --download-only "$pkg" "$ver" ) \
            || { echo "no source for $pkg $ver" >&2; exit 1; }
    done < "$W/srcpkgs.txt"
    cp "$W/srcpkgs.txt" "$S/ubuntu/PACKAGES.txt"
fi

tar -C "$W" -cf "$OUT" melo-sources
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)); unresolved libraries: $(wc -l < "$S/UNRESOLVED.txt")"
