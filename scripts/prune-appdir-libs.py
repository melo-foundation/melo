#!/usr/bin/env python3
"""Remove AppDir libs nothing bundled actually links.

linuxdeploy walks the FULL dependency closure, then we exclude some roots
(system gstreamer, glib, libxml2...) — but their already-walked deps stay
bundled as orphans (libdw, libzstd, libpcre.so.3 ~2MB+). Rebuild the closure
from what actually ships and delete the rest.

Roots: the app binary + every dlopen'd tree (gstreamer-1.0, gio modules) +
bundled node. NEEDED names resolve within usr/lib (symlink chains followed).
"""
import glob
import os
import subprocess
import sys

appdir = sys.argv[1]
libdir = os.path.join(appdir, "usr/lib")
# extra roots: libs reached only via dlopen (no DT_NEEDED anywhere) —
# e.g. libgstsoup dlopens libsoup-2.4
extra_roots = [os.path.join(appdir, p) for p in sys.argv[2:]]


def needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return [l.split("[")[1].split("]")[0] for l in out.splitlines() if "(NEEDED)" in l]


roots = [os.path.join(appdir, "usr/bin/melo")]
roots += glob.glob(os.path.join(libdir, "gstreamer-1.0/*.so"))
roots += glob.glob(os.path.join(libdir, "gio/modules/*.so"))
node = os.path.join(appdir, "usr/bin/node")
if os.path.exists(node):
    roots.append(node)
for r in extra_roots:
    if os.path.exists(r):
        roots.append(os.path.realpath(r))
        keep_name = os.path.basename(r)


keep = set(os.path.basename(r) for r in extra_roots)
frontier = []
for r in roots:
    frontier += needed(r)
while frontier:
    name = frontier.pop()
    if name in keep:
        continue
    p = os.path.join(libdir, name)
    if os.path.exists(p):
        keep.add(name)
        frontier += needed(os.path.realpath(p))

pruned = 0
for f in sorted(os.listdir(libdir)):
    p = os.path.join(libdir, f)
    if not os.path.isfile(p) and not os.path.islink(p):
        continue
    # keep a real file when its name OR any soname-symlink prefix survives
    # (libfoo.so.1.2.3 stays because NEEDED libfoo.so.1 resolved to it)
    if f in keep or any(f.startswith(k) for k in keep):
        continue
    size = 0 if os.path.islink(p) else os.path.getsize(p)
    print(f"prune: {f} ({size // 1024}K)")
    os.remove(p)
    pruned += size
print(f"pruned {pruned // 1024}K total")
