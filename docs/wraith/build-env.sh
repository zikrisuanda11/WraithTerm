#!/usr/bin/env bash
# WraithTerm build environment setup (ADR-003).
#
# The host lacks some -devel packages and has no system Zig. We build
# entirely user-local without root:
#   1. Zig 0.16.0 unpacked to ~/.local/opt/zig (from ziglang.org).
#   2. blueprint-compiler via `pip3 install --user blueprint-compiler`.
#   3. Missing dev headers/libs extracted from Fedora RPMs into a private
#      sysroot at ~/.local/wraith-sysroot (rpm2cpio | cpio, no install).
#
# Usage:  source docs/wraith/build-env.sh        (sets env for this shell)
#         docs/wraith/build-env.sh --setup       (also (re)create zig+sysroot)
#
# Source this before every `zig build` / `zig build test`.

WRAITH_SYS="$HOME/.local/wraith-sysroot"
WRAITH_ZIG="$HOME/.local/opt/zig"

setup_sysroot() {
  set -e
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$WRAITH_SYS"
  echo "downloading devel RPMs -> $tmp"
  dnf download --destdir "$tmp" \
    --setopt=repo_gpgcheck=False --setopt=gpgcheck=False \
    libadwaita-devel gtk4-layer-shell-devel appstream-devel
  ( cd "$WRAITH_SYS" && for r in "$tmp"/*.x86_64.rpm; do rpm2cpio "$r" | cpio -idm --quiet; done )
  # Rewrite .pc files so pkg-config emits sysroot-relative paths.
  find "$WRAITH_SYS/usr/lib64/pkgconfig" -name '*.pc' -exec sed -i "s|/usr|$WRAITH_SYS/usr|g" {} +
  # The .so dev symlinks point at libs that live in the main package.
  ln -sf /usr/lib64/libadwaita-1.so.0 "$WRAITH_SYS/usr/lib64/libadwaita-1.so.0"
  ln -sf /usr/lib64/libgtk4-layer-shell.so.0 "$WRAITH_SYS/usr/lib64/libgtk4-layer-shell.so.0"
  echo "sysroot ready: $WRAITH_SYS"
}

if [ "${1:-}" = "--setup" ]; then
  [ -x "$WRAITH_ZIG/zig" ] || { echo "Zig missing at $WRAITH_ZIG — see ADR-001"; exit 1; }
  command -v blueprint-compiler >/dev/null || pip3 install --user blueprint-compiler
  [ -f "$WRAITH_SYS/usr/include/libadwaita-1/adwaita.h" ] || setup_sysroot
fi

export PATH="$WRAITH_ZIG:$HOME/.local/bin:$PATH"
export PKG_CONFIG_PATH="$WRAITH_SYS/usr/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig"
export LIBRARY_PATH="$WRAITH_SYS/usr/lib64"
echo "wraith build env: zig=$(zig version 2>/dev/null) sysroot=$WRAITH_SYS"
