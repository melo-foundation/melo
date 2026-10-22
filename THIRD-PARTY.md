# Third-party components

melo is © 2026 melo-foundation, GPL-3.0-or-later (see `LICENSE`). The components
below carry their own terms. The LGPL texts are in `LICENSES/`.

## In this repository

| Component | Licence | Where |
|---|---|---|
| Red Hat Display | OFL-1.1 | `assets/fonts/`, licence text alongside |
| KWin `blur` and `contrast` Wayland protocols | LGPL-2.1-or-later | `protocols/blur.xml`, `protocols/contrast.xml` |
| `ext-background-effect-v1` Wayland protocol, from wayland-protocols 1.49 | MIT, notice in the file | `protocols/ext-background-effect-v1.xml` |
| `xdg-shell` Wayland protocol, from wayland-protocols as vendored in qtwayland 6.11.2 | MIT, notice in the file | `protocols/xdg-shell.xml` |
| Feather icons `search`, `x`, `shuffle` and `sliders` (path data) | MIT, notice below | `src/qml/style/Theme.qml`: glyphs `search`, `close`, `shuffle`, `eq` |

## In the Linux packages (AppImage, rpm, deb, Arch)

| Component | Licence | Linked |
|---|---|---|
| Qt 6.12.0 (qtbase, qtdeclarative, qtwayland, qtimageformats, qt5compat, qtshadertools), modified | LGPL-3.0-only | static |
| HarfBuzz, libpng, libjpeg, PCRE2, zlib and libwebp as built into Qt | their own licences, listed in Qt's third-party attributions | static |
| ICU 73.2 | Unicode-DFS-2016 | static |
| projectM 4.1.7, modified | LGPL-2.1-or-later | static |
| projectm-eval, hlslparser (built into projectM) | MIT | static |
| glm (built into projectM) | MIT | static |
| SOIL2 and stb_image (built into projectM) | public domain (stb_image: public domain or MIT) | static |
| zlib | Zlib | shared |
| wayland-client | MIT | shared |
| FFmpeg 7.1.1, minimal build, unmodified | LGPL-2.1-or-later; text in `share/melo/ffmpeg-COPYING.LGPLv2.1` | separate program |

The full AppImage also ships:

| Component | Licence |
|---|---|
| GStreamer 1.0 core and the base, good and bad plugins it uses | LGPL-2.1-or-later |
| GStreamer `faad` plugin and libfaad2 | GPL-2.0-or-later |
| glib, glib-networking | LGPL-2.1-or-later |
| libsoup 2.4 | LGPL-2.0-or-later |
| GnuTLS | LGPL-2.1-or-later |
| libogg, libvorbis, libopus, libFLAC | BSD-3-Clause |
| libmpg123 | LGPL-2.1-only |
| Node.js 22.23.4 | MIT and the licences in `share/melo/node-LICENSE` |

and the shared libraries these depend on, listed in `usr/lib` inside the
AppImage.

The AppImage runtimes, the executable part at the start of each file:

| AppImage | Runtime | Licence |
|---|---|---|
| both | type2-runtime release 20251108 (commit dd6cebe), from github.com/AppImage/type2-runtime | MIT |
| both | libfuse 3.15.0 (library), squashfuse 0.5.2, zstd, zlib and mimalloc, linked into that runtime | in that order: LGPL-2.1-only, BSD-2-Clause, BSD-3-Clause OR GPL-2.0-only, Zlib, MIT |

The anylinux AppImage (`melo-anylinux-x86_64.AppImage`) ships the full
AppImage's melo, Node.js, FFmpeg and AV1 plugin with Arch Linux's builds of
the libraries they load. Each package, its version and its licence is listed in
`share/melo/arch-packages.txt` inside the AppImage, with the packages' licence
files and the SPDX texts in `share/melo/arch-licenses/`. Among them:

| Component | Licence |
|---|---|
| glibc | LGPL-2.1-or-later |
| libstdc++ and libgcc | GPL-3.0-or-later WITH GCC-exception-3.1 |
| Mesa 26.2.3 (Arch) | MIT AND BSD-3-Clause AND SGI-B-2.0 |
| LLVM 22.1.8 libraries, X86 and AMDGPU targets only, from github.com/pkgforge-dev/archlinux-pkgs-debloated | Apache-2.0 WITH LLVM-exception |
| libglvnd | BSD-like, text in `share/melo/arch-licenses/libglvnd/` |
| GStreamer 1.0 core and the base, good and bad plugins it uses | LGPL-2.1-or-later |
| GStreamer `faad` plugin and libfaad2 | GPL-2.0-or-later |
| glib, glib-networking, libsoup 3, GnuTLS | LGPL-2.1-or-later (libsoup: LGPL-2.0-or-later) |
| OpenSSL 3 | Apache-2.0 |
| sharun 3.5.1, from github.com/pkgforge-dev/Anylinux-sharun, with its helper libraries | MIT, text in `share/melo/sharun-LICENSE` |
| The AppRun scripts and hooks of quick-sharun, github.com/pkgforge-dev/Anylinux-AppImages commit 48137df | MIT, text in `share/melo/anylinux-AppImages-LICENSE` |

| AppImage | Runtime | Licence |
|---|---|---|
| anylinux | uruntime v0.8.1 (`uruntime-appimage-squashfs`), from github.com/VHSgunzo/uruntime | MIT, text in `share/melo/uruntime-LICENSE` |
| anylinux | squashfuse 0.6.3 (with libfuse 3.18.2, musl and mimalloc) and squashfs-tools 4.7.5 `unsquashfs`, static, embedded in that runtime | BSD-2-Clause (libfuse: LGPL-2.1-only, musl: MIT, mimalloc: MIT), GPL-2.0-or-later |

The lite AppImage and the rpm, deb and Arch packages use the system's
GStreamer and fontconfig. The rpm and deb packages ship Node.js 22.23.4
(MIT, licence at `/usr/lib/melo/share/melo/node-LICENSE`); the lite
AppImage and the Arch package use the system's Node.js.

## In the Windows build

| Component | Licence |
|---|---|
| Qt 6.7 | LGPL-3.0-only |
| projectM 4.1.6, modified | LGPL-2.1-or-later |
| GLEW | BSD-3-Clause AND MIT |
| GStreamer runtime DLLs | the notices shipped with the GStreamer runtime |
| Node.js 22 | MIT and the licences in Node's LICENSE |
| Microsoft Visual C++ runtime | Microsoft's redistributable terms |

## Sidecar

Bundled into `melo-sidecar.mjs`:

| Component | Licence |
|---|---|
| youtubei.js | MIT |
| @bufbuild/protobuf | Apache-2.0 AND BSD-3-Clause |
| fflate | MIT |
| meriyah | ISC |
| bgutils-js | MIT |
| openpgp 6.3.2 | LGPL-3.0-or-later |

Shipped as `share/melo/node_modules/`, each package with its own licence file:
jsdom and its dependencies.

## Presets

The packages include up to 800 MilkDrop presets from
github.com/projectM-visualizer/presets-cream-of-the-crop, each by its own
author. They were released without a licence; the projectM team treats them as
public domain and removes any preset on its author's request.

## Downloaded at runtime

| Component | Source | Licence |
|---|---|---|
| Node.js 22.23.4, SHA-256 pinned (lite AppImage and the Arch package, when the system Node is missing or older than 22.22.2) | nodejs.org | MIT |
| yt-dlp | github.com/yt-dlp/yt-dlp | Unlicense |

No Winamp skin archives are included.

## LGPL obligations

The Linux packages link Qt and projectM statically, and both are modified. The
lite AppImage's runtime links libfuse 3.15.0 statically, with the runtime's own
`patches/libfuse/mount.c.diff`.

- **Modifications.** Qt: `patches/qtdeclarative-6.12.0-stacking-walk.patch`,
  written by Tomasz Kalisiak as Qt Gerrit change 736359 (QTBUG-134949, not
  merged upstream), backported to Qt 6.12.0 by melo-foundation on 2026-10-08.
  projectM: `patches/projectm-caller-fbo.patch`, modified by melo-foundation
  for melo on 2026-09-02.
- **Source.** Every Linux release has `melo-sources.tar` beside its builds: the
  source of Qt 6.12.0, projectM 4.1.7 and FFmpeg 7.1.1 with melo's patches, the
  type2-runtime 20251108 source with libfuse 3.15.0 and squashfuse 0.5.2, and
  the Ubuntu source package of every library the full AppImage bundles, and
  for the anylinux AppImage: the Arch packaging and upstream sources of every
  GPL or LGPL package it bundles, at the versions bundled, and the uruntime,
  squashfuse, libfuse, squashfs-tools, sharun, quick-sharun and
  cross-libc-dlopen sources at the commits its runtime and tools were built
  from. `scripts/release-sources.sh` builds it.
- **Relinking.** To use your own Qt or projectM, build melo from this source
  against a shared Qt, and run `scripts/setup-vendor.sh` without `--static`.
  To use your own libfuse in the lite AppImage, build type2-runtime from its
  source against it, run `melo-lite-x86_64.AppImage --appimage-extract`, and
  repack `squashfs-root` with `appimagetool --runtime-file <your runtime>`.

## Feather icons

Copyright (c) 2013-2023 Cole Bemis. github.com/feathericons/feather

```
The MIT License (MIT)

Copyright (c) 2013-2023 Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
