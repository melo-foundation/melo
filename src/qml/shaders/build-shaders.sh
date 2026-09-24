#!/bin/bash
# Concatenate each *.frag.in with common.glsl (spliced at //COMMON//) and
# compile to .qsb (GLSL for the GL scene graph + HLSL/MSL for the Windows
# D3D fallback and any future backend). Rerun after editing shaders; the
# .qsb files are committed so builds/CI need no shader toolchain.
set -e
QSB="${QSB:-/usr/lib64/qt6/bin/qsb}"
cd "$(dirname "$0")"
for f in *.frag.in; do
  base="${f%.frag.in}"
  awk '/^\/\/COMMON\/\/$/ { while ((getline line < "common.glsl") > 0) print line; next } { print }' "$f" > "$base.frag.tmp"
  # A desktop GL core context takes the 150 variant; main.cpp requests OpenGL
  # 3.3, so Qt never picks ES. Do not switch to --qt6 / "100 es": that output uses
  # fragment `attribute`/`varying`, texture2DLod and GL_EXT_gpu_shader4 integer
  # ops, which desktop compilers reject, and qsb's ES variants here lack the
  # precision qualifiers ES requires.
  "$QSB" --glsl "300 es,120,150" --hlsl 50 --msl 12 -o "$base.frag.qsb" "$base.frag.tmp"
  rm "$base.frag.tmp"
  echo "built $base.frag.qsb"
done
