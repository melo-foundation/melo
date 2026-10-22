#!/bin/sh
# The full AppImage's melo, Node, FFmpeg and AV1 plugin, rewrapped with sharun:
# its own glibc, Mesa and GStreamer, so it runs on musl and older glibc, and it
# extracts and runs where there is no FUSE.
#
#   scripts/anylinux-appimage.sh <AppDir> <out dir> <update information>
#
# Runs as root in an archlinux:latest container; release.yml mounts the AppDir
# read-only. Writes melo-anylinux-x86_64.AppImage and its .zsync to <out dir>.
set -eu

IN=$(cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
UPINFO=$3
NAME=melo-anylinux-x86_64.AppImage

# quick-sharun pins sharun 3.5.1 and cross-libc-dlopen by sha256 itself
ANYLINUX_COMMIT=48137dfbe0f1279aad007d63975d1035350f4cdf
QUICK_SHARUN_SHA256=238a5c2a1d8833ab4a94fe9c91b8ff5eb92b0c35119fa8c2e9f5b25cdb71e979
ANYLINUX_LICENSE_SHA256=78a983481f226ae0ee56d72fb73a027ce51f72ff40ec8ab3b55e8866ca9f2f7f
SHARUN_VERSION=3.5.1
SHARUN_LICENSE_SHA256=ed1795c447be9b4ae96262f583b559f733a82f627b0265f860f22488c7f8b2ff
# SquashFS: AppImageHub and libappimage cannot read the DwarFS of the default uruntime
URUNTIME_VERSION=v0.8.1
URUNTIME_SHA256=2153e68d63f570c7ebe3d1f38df0fa16814f34d839c5cce2ee42667e327708e8
URUNTIME_LICENSE_SHA256=c4b670b0607ef626e670733093c9e4304b3bacc5076742de826d45f83e12e9d3
# Mesa with llvmpipe: without LLVM a GPU-less machine gets softpipe, 300 ms a frame.
# pkgforge-dev's LLVM keeps only the X86 and AMDGPU targets; Mesa must be the Arch
# build made on that LLVM version. Upstream replaces the LLVM file in place.
MESA_PKG="https://archive.archlinux.org/packages/m/mesa/mesa-1%3A26.2.3-1-x86_64.pkg.tar.zst"
MESA_SHA256=8365cf2f7f8b55619b3deb52112f402e1db6204a48b60447795631955d832e6c
LLVM_PKG=https://github.com/pkgforge-dev/archlinux-pkgs-debloated/releases/download/continuous/llvm-libs-nano-x86_64.pkg.tar.zst
LLVM_SHA256=f186b7d2f8367e3b53f0192a9ad60e69987188efa7a2c0770577fb3f03981170

# the full AppImage's plugin set; videoconvert is videoconvertscale since GStreamer 1.22
PLUGINS="coreelements app playback typefindfunctions audioconvert audioresample volume
autodetect audiomixer equalizer audioparsers ogg vorbis opus opusparse faad mpg123 flac
wavparse isomp4 matroska id3demux soup pulseaudio alsa vpx videoconvertscale videoparsersbad audiofx"

pacman -Syu --noconfirm --needed \
	patchelf strace binutils wget file findutils xorg-server-xvfb xorg-xauth \
	squashfs-tools zsync dbus \
	libglvnd mesa libdrm wayland \
	libxcb xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil \
	xcb-util-wm libxkbcommon libxkbcommon-x11 libx11 libsm libice \
	fontconfig freetype2 systemd-libs zlib \
	gstreamer gst-plugins-base gst-plugins-base-libs gst-plugins-good gst-plugins-bad \
	gst-plugins-ugly glib-networking libsoup3 libpulse alsa-lib

T=$(mktemp -d)
fetch() {   # fetch <url> <file> <sha256>
	curl -fsSL --retry 3 -o "$2" "$1"
	echo "$3  $2" | sha256sum -c --quiet
}
A=https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/$ANYLINUX_COMMIT
fetch "$A/useful-tools/quick-sharun.sh" "$T/quick-sharun" "$QUICK_SHARUN_SHA256"
fetch "$A/LICENSE" "$T/anylinux-LICENSE" "$ANYLINUX_LICENSE_SHA256"
fetch "https://raw.githubusercontent.com/pkgforge-dev/Anylinux-sharun/$SHARUN_VERSION/LICENSE" \
	"$T/sharun-LICENSE" "$SHARUN_LICENSE_SHA256"
fetch "https://github.com/VHSgunzo/uruntime/releases/download/$URUNTIME_VERSION/uruntime-appimage-squashfs-x86_64" \
	"$T/uruntime" "$URUNTIME_SHA256"
fetch "https://raw.githubusercontent.com/VHSgunzo/uruntime/$URUNTIME_VERSION/LICENSE" \
	"$T/uruntime-LICENSE" "$URUNTIME_LICENSE_SHA256"
chmod +x "$T/quick-sharun" "$T/uruntime"

fetch "$MESA_PKG" "$T/mesa.pkg.tar.zst" "$MESA_SHA256"
fetch "$LLVM_PKG" "$T/llvm-libs.pkg.tar.zst" "$LLVM_SHA256" \
	|| { echo "llvm-libs-nano changed upstream: pin its new build and the Mesa built on that LLVM"; exit 1; }
pacman -U --noconfirm --ask 4 "$T/mesa.pkg.tar.zst" "$T/llvm-libs.pkg.tar.zst"
pacman -Q mesa llvm-libs

# quick-sharun deploys every plugin in the directory: keep melo's set, plus its AV1 plugin
GST=/usr/lib/gstreamer-1.0
mkdir "$T/keep"
for p in $PLUGINS; do
	mv "$GST/libgst$p.so" "$T/keep/" || { echo "no GStreamer plugin $p"; exit 1; }
done
rm -f "$GST"/*.so
mv "$T"/keep/*.so "$GST"/
cp "$IN/usr/lib/gstreamer-1.0/libgstdav1d.so" "$GST"/

# quick-sharun takes installed programs
cp "$IN/usr/bin/melo" "$IN/usr/bin/node" "$IN/usr/bin/ffmpeg" /usr/bin/

export CI=1   # lets quick-sharun prune the plugin directory
export APPDIR="$T/AppDir"
export DESKTOP="$IN/usr/share/applications/melo.desktop"
export ICON="$IN/usr/share/icons/hicolor/512x512/apps/melo.png"
export MAIN_BIN=melo
export DEPLOY_OPENGL=1 DEPLOY_VULKAN=0 DEPLOY_GSTREAMER=1 DEPLOY_PULSE=1
export STRACE_BINARY=melo STRACE_TIME=10
export MELO_CONFIG_DIR="$T/strace-config" MELO_NO_SPLASH=1
mkdir -p "$MELO_CONFIG_DIR"
# Qt opens OpenSSL at runtime for thumbnails and update checks
"$T/quick-sharun" /usr/bin/melo /usr/bin/node /usr/bin/ffmpeg /usr/lib/gio/modules/libgiognutls.so \
	/usr/lib/libssl.so.3 /usr/lib/libcrypto.so.3

# melo looks for these beside its executable, and in ../share/melo
cp -r "$IN/usr/bin/melo-qml" "$IN/usr/bin/presets" "$IN/usr/bin/fonts" "$APPDIR/bin/"
mkdir -p "$APPDIR/share/melo" "$APPDIR/share/metainfo"
cp -r "$IN/usr/share/melo/." "$APPDIR/share/melo/"
cp "$IN"/usr/share/metainfo/*.xml "$APPDIR/share/metainfo/"

# the bundled Arch packages: name, version and licence, and their licence files
L="$APPDIR/share/melo"
cp "$T/anylinux-LICENSE" "$L/anylinux-AppImages-LICENSE"
cp "$T/sharun-LICENSE" "$L/sharun-LICENSE"
cp "$T/uruntime-LICENSE" "$L/uruntime-LICENSE"
find "$APPDIR/lib/" -type f | while read -r f; do
	pacman -Qqo "/usr/lib/${f#"$APPDIR/lib/"}" 2>/dev/null || :
done | sort -u > "$T/pkgs"
mkdir -p "$L/arch-licenses/spdx"
while read -r p; do
	pacman -Qi "$p" | awk -v p="$p" '/^Version/{v=$3} /^Licenses/{sub(/^Licenses *: */,""); l=$0} END{print p, v, l}'
	# the image leaves out /usr/share/doc, where some of these links point
	for f in "/usr/share/licenses/$p"/*; do
		[ -e "$f" ] || continue
		mkdir -p "$L/arch-licenses/$p"
		cp -rL "$f" "$L/arch-licenses/$p/"
	done
done < "$T/pkgs" > "$L/arch-packages.txt"
cat "$L/arch-packages.txt"
# the source packages of the GPL and LGPL ones, for release-sources.sh
while read -r p v lic; do
	case "$lic" in *GPL*) sed -n '/^%BASE%$/{n;p;q}' /var/lib/pacman/local/"$p-$v"/desc | sed "s/\$/ $v/" ;; esac
done < "$L/arch-packages.txt" | sort -u > "$L/arch-sources.txt"
cp "$L/arch-sources.txt" "$OUT/"
# the full text of every SPDX licence named there
for id in $(cut -d' ' -f3- "$L/arch-packages.txt" | tr ' ()' '\n\n\n' | sort -u); do
	f=/usr/share/licenses/spdx/$id.txt
	if [ -f "$f" ]; then cp "$f" "$L/arch-licenses/spdx/"; fi
done

# melo's env (the full AppImage's apprun-hooks/melo-env.sh); sharun sets the GST and GIO paths
cat >> "$APPDIR/.env" <<'EOF'
MELO_NODE=${SHARUN_DIR}/bin/node
GST_REGISTRY=${HOME}/.cache/melo-anylinux-gst-registry.bin
EOF
# Set by the runtime, before AppRun.lib reads them. The host cache: melo keeps its QML
# copy, shader cache and thumbnails there. No reuse delay: the mount goes as melo
# exits, so the file can be replaced at once (6 s busy with the default).
printf '%s\n' USE_HOST_XDG_CACHE_HOME=1 REUSE_CHECK_DELAY=0 > "$T/runtime.env"

# glibc 2.44's resolver fails A and AAAA lookups sent together on kernels before 3.2
cat > "$APPDIR/bin/10-melo-resolver.hook" <<'EOF'
#!/bin/sh
if [ -z "${RES_OPTIONS+x}" ] && read -r _k 2>/dev/null < /proc/sys/kernel/osrelease; then
	case $_k in 2.*|3.0|3.0[.-]*|3.1|3.1[.-]*) export RES_OPTIONS=single-request ;; esac
fi
EOF

# zstd 22 and 1 MiB blocks, as the full AppImage
mksquashfs "$APPDIR" "$T/fs" -root-owned -noappend -no-xattrs -quiet -no-progress \
	-comp zstd -Xcompression-level 22 -b 1M
cp "$T/uruntime" "$OUT/$NAME"
"$OUT/$NAME" --appimage-addupdinfo "$UPINFO"
"$OUT/$NAME" --appimage-addenvs "$T/runtime.env"
cat "$T/fs" >> "$OUT/$NAME"
( cd "$OUT" && zsyncmake -u "$NAME" -o "$NAME.zsync" "$NAME" )
du -m "$OUT/$NAME"
rm -rf "$T"
