#!/usr/bin/env bash
# One tar of corresponding source for every LGPL/GPL component the Linux builds
# ship, attached beside the binaries. Qt and projectM are static and patched;
# FFmpeg ships as a program; the lite AppImage's runtime links libfuse
# statically; the full AppImage carries Ubuntu's shared libraries, the anylinux
# AppImage Arch's, and a runtime with libfuse and squashfs-tools built in.
#
#   scripts/release-sources.sh <AppDir> <out.tar> [arch-sources.txt]
#
# arch-sources.txt: "<pkgbase> <version>" per line, as anylinux-appimage.sh writes it.
#
# Needs deb-src enabled for `apt-get source`; versions the mirror dropped come
# from Launchpad (pull-lp-source, ubuntu-dev-tools). Libraries no Ubuntu package
# owns are listed in UNRESOLVED.txt inside the tar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="${1:?usage: $0 <AppDir> <out.tar>}"
OUT="$(realpath -m "${2:?usage: $0 <AppDir> <out.tar>}")"
ARCH_LIST="${3:+$(realpath "$3")}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
S="$W/melo-sources"
mkdir -p "$S/qt" "$S/projectm" "$S/ffmpeg" "$S/ubuntu"

# --- Qt: the modules the static build compiles, and melo's patch ------------
QT=6.12.0
QTBASE="https://download.qt.io/archive/qt/${QT%.*}/$QT/submodules"
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

# --- the anylinux AppImage: its runtime, sharun, and the Arch packages ------
# uruntime v0.8.1 embeds squashfuse-static v0.6.3.r2 and squashfs-tools-static
# v4.7.5.r2 (its build_support.rs); each of those pins its upstream commits.
if [ -n "$ARCH_LIST" ]; then
    AL="$S/anylinux"
    mkdir -p "$AL/arch"
    pin() { sed -n "s/^$1=\(.*\)$/\1/p" "$ROOT/scripts/anylinux-appimage.sh"; }
    gh_src() {   # gh_src <owner/repo> <tag or commit> <out name>
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o "$AL/$3.tar.gz" "https://github.com/$1/archive/$2.tar.gz"
    }
    gh_src VHSgunzo/uruntime "refs/tags/$(pin URUNTIME_VERSION)" "uruntime-$(pin URUNTIME_VERSION)"
    gh_src VHSgunzo/squashfuse-static 6a4acb585b00309563a1fcffa1c143f21d9ac96b squashfuse-static-v0.6.3.r2
    gh_src vasi/squashfuse 1a211e20fff55e9ce4c74ad03f0aa26a7b760bd3 squashfuse-0.6.3
    gh_src libfuse/libfuse 033844748010a3b8265bf1c90b9ae8ffe4cd9ca7 libfuse-3.18.2
    gh_src VHSgunzo/squashfs-tools-static 7b2e08bfc1787d8c4f06ffd399b25b1b9c29d6df squashfs-tools-static-v4.7.5.r2
    gh_src plougher/squashfs-tools 708c59ae80853b0845017c33b42e56061cc546cd squashfs-tools-4.7.5
    gh_src pkgforge-dev/Anylinux-sharun "refs/tags/$(pin SHARUN_VERSION)" "Anylinux-sharun-$(pin SHARUN_VERSION)"
    gh_src pkgforge-dev/Anylinux-AppImages "$(pin ANYLINUX_COMMIT)" "Anylinux-AppImages-$(pin ANYLINUX_COMMIT)"
    gh_src pkgforge-dev/cross-libc-dlopen refs/tags/v0.2.7 cross-libc-dlopen-v0.2.7

    # Each Arch package at the version bundled: its packaging (PKGBUILD and
    # patches) at that tag, and every source its .SRCINFO names. A git commit
    # whose host is gone comes from Software Heritage; what neither has is
    # listed in anylinux/UNRESOLVED.txt.
    C="curl -fsSL --retry 5 --retry-all-errors --retry-delay 5"
    : > "$AL/UNRESOLVED.txt"
    # Commits whose host is gone, kept on melo-foundation/build-inputs: commit, file, sha256.
    # Software Heritage's vault can sit queued past the wait below for hours.
    MIRRORED="68cd5aff1467638c086f1bedcc750e34917168e4 libasyncns-68cd5af/libasyncns-68cd5aff1467638c086f1bedcc750e34917168e4.tar.gz 69597d5a2791f857f1660888d60cf5bf59284c972a4f318bba064752b0641436"
    mirrored() {   # mirrored <commit> <out.tar.gz>
        local c f s
        while read -r c f s; do
            [ "$c" = "$1" ] || continue
            $C -o "$2" "https://github.com/melo-foundation/build-inputs/releases/download/$f" || return 1
            echo "$s  $2" | sha256sum -c --quiet || { rm -f "$2"; return 1; }
            return 0
        done <<< "$MIRRORED"
        return 1
    }
    swh() {   # swh <commit> <out.tar.gz>: the commit's tree from the archive's vault
        local api=https://archive.softwareheritage.org/api/1 dir st i
        dir=$($C "$api/revision/$1/" | sed -n 's/.*"directory":"\([0-9a-f]*\)".*/\1/p') || return 1
        [ -n "$dir" ] || return 1
        $C -X POST "$api/vault/flat/swh:1:dir:$dir/" > /dev/null || return 1
        for i in $(seq 90); do
            st=$($C "$api/vault/flat/swh:1:dir:$dir/" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p') || st=""
            if [ "$st" = done ]; then $C -o "$2" "$api/vault/flat/swh:1:dir:$dir/raw/"; return; fi
            [ "$st" = failed ] && return 1
            sleep 10
        done
        return 1
    }
    while read -r base ver; do
        [ -n "$base" ] || continue
        tag=$(printf '%s' "$ver" | tr ':' '-')
        d="$AL/arch/$base-$tag"
        P="https://gitlab.archlinux.org/archlinux/packaging/packages/$base/-"
        mkdir -p "$d"
        $C -o "$d/packaging.tar.gz" "$P/archive/$tag/$base-$tag.tar.gz"
        $C "$P/raw/$tag/.SRCINFO" | sed -n 's/^\tsource\(_x86_64\)\{0,1\} = //p' > "$W/srcinfo"
        while read -r s; do
            name=""; url=$s
            case "$s" in *::*) name=${s%%::*}; url=${s#*::} ;; esac
            case "$url" in
            git+*)
                u=${url#git+}; frag=""
                case "$u" in *'#'*) frag=${u#*#}; u=${u%%#*} ;; esac
                u=${u%%\?*}; ref=${frag#*=}; ref=${ref%%\?*}; [ -n "$ref" ] || ref=HEAD
                n=${name:-$(basename "${u%.git}")}
                g="$W/git"; rm -rf "$g"; git init -q "$g"
                if git -C "$g" fetch -q --depth 1 "$u" "$ref" 2>/dev/null \
                        || git -C "$g" fetch -q "$u" "$ref" 2>/dev/null; then
                    git -C "$g" archive --prefix="$n/" -o "$d/$n.tar.gz" FETCH_HEAD
                elif ! { [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && { mirrored "$ref" "$d/$n.tar.gz" || swh "$ref" "$d/$n.tar.gz"; }; }; then
                    echo "$base $ver $url" >> "$AL/UNRESOLVED.txt"
                fi
                rm -rf "$g" ;;
            http://*|https://*|ftp://*)
                $C -o "$d/${name:-${url##*/}}" "$url" || echo "$base $ver $url" >> "$AL/UNRESOLVED.txt" ;;
            esac   # anything else is a file in the packaging tarball
        done < "$W/srcinfo"
    done < "$ARCH_LIST"
    cp "$ARCH_LIST" "$AL/arch/PACKAGES.txt"
fi

tar -C "$W" -cf "$OUT" melo-sources
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)); unresolved libraries: $(wc -l < "$S/UNRESOLVED.txt")"
[ -z "$ARCH_LIST" ] || echo "anylinux sources unresolved: $(wc -l < "$S/anylinux/UNRESOLVED.txt")"
