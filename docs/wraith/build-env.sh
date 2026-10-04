#!/usr/bin/env bash
# WraithTerm build environment setup (ADR-003, ADR-005).
#
# The host lacks some -devel packages and has no system Zig. We build
# entirely user-local without root:
#   1. Zig 0.16.0 unpacked to ~/.local/opt/zig (from ziglang.org).
#   2. blueprint-compiler via `pip3 install --user blueprint-compiler`
#      (manual wheel fallback when pip itself is broken).
#   3. Fedora: missing dev headers/libs extracted from RPMs into a private
#      sysroot at ~/.local/wraith-sysroot (rpm2cpio | cpio, no install).
#   4. Arch/CachyOS: native headers exist; instead mirror glibc CRT objects
#      user-local with .sframe stripped (objcopy) + ZIG_LIBC override,
#      because Zig 0.16.0 cannot link R_X86_64_PC64 (glibc>=2.44).
#
# Usage:  source docs/wraith/build-env.sh        (sets env for this shell)
#         docs/wraith/build-env.sh --setup       (also (re)create zig+sysroot)
#
# Source this before every `zig build` / `zig build test`.

WRAITH_SYS="$HOME/.local/wraith-sysroot"
WRAITH_ZIG="$HOME/.local/opt/zig"
WRAITH_CRT="$HOME/.local/wraith-crt"
WRAITH_LIBC="$WRAITH_CRT/libc.txt"

setup_sysroot() {
  set -e
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$WRAITH_SYS"
  echo "downloading devel RPMs -> $tmp"
  # Pin the -devel versions to the runtime libraries installed on this host.
  # A header/runtime version mismatch fails src/apprt/gtk/adw_version.zig test
  # (atLeast() compares ADW_*_VERSION macros against the linked .so).
  local adw_ver gtk_layer_ver appstream_ver
  adw_ver="$(rpm -q --qf '%{VERSION}' libadwaita)"
  gtk_layer_ver="$(rpm -q --qf '%{VERSION}' gtk4-layer-shell)"
  appstream_ver="$(rpm -q --qf '%{VERSION}' appstream)"
  # Fedora's repo may serve a newer -devel than the installed runtime; try the
  # exact koji build first, then the repo, then an unpinned download.
  fetch_rpm() { # name version arch
    local name="$1" ver="$2" arch="$3" out="$tmp/$name-$ver.$arch.rpm"
    local u="https://kojipkgs.fedoraproject.org/packages/${name%-devel}/$ver/1.fc43/$arch/$name-$ver-1.fc43.$arch.rpm"
    curl -sfL "$u" -o "$out" && { echo "koji: $out"; return 0; }
    return 1
  }
  if ! fetch_rpm libadwaita-devel "$adw_ver" x86_64 ||
     ! fetch_rpm gtk4-layer-shell-devel "$gtk_layer_ver" x86_64 ||
     ! fetch_rpm appstream-devel "$appstream_ver" x86_64; then
    echo "koji miss; falling back to repo download (versions may drift)"
    dnf download --destdir "$tmp" \
      --setopt=repo_gpgcheck=False --setopt=gpgcheck=False \
      libadwaita-devel gtk4-layer-shell-devel appstream-devel
  fi
  ( cd "$WRAITH_SYS" && for r in "$tmp"/*.x86_64.rpm; do rpm2cpio "$r" | cpio -idm --quiet; done )
  # Rewrite .pc files so pkg-config emits sysroot-relative paths.
  find "$WRAITH_SYS/usr/lib64/pkgconfig" -name '*.pc' -exec sed -i "s|/usr|$WRAITH_SYS/usr|g" {} +
  # The .so dev symlinks point at libs that live in the main package.
  ln -sf /usr/lib64/libadwaita-1.so.0 "$WRAITH_SYS/usr/lib64/libadwaita-1.so.0"
  ln -sf /usr/lib64/libgtk4-layer-shell.so.0 "$WRAITH_SYS/usr/lib64/libgtk4-layer-shell.so.0"
  ln -sf /usr/lib64/libappstream.so.5 "$WRAITH_SYS/usr/lib64/libappstream.so.5"
  echo "sysroot ready: $WRAITH_SYS (libadwaita-devel=$adw_ver)"
}

setup_sanitized_crt() {
  set -e
  command -v objcopy >/dev/null || { echo "objcopy missing (binutils)"; return 1; }
  command -v gcc >/dev/null || { echo "gcc missing (for crtbegin path)"; return 1; }
  local gccdir f
  gccdir="$(dirname "$(gcc -print-file-name=crtbegin.o)")"
  mkdir -p "$WRAITH_CRT"
  echo "mirroring CRT objects -> $WRAITH_CRT"
  for f in crt1.o crti.o crtn.o Scrt1.o rcrt1.o gcrt1.o Mcrt1.o; do
    if [ -e "/usr/lib/$f" ]; then
      cp -f "/usr/lib/$f" "$WRAITH_CRT/$f"
      objcopy --remove-section .sframe --remove-section .sframe_seg "$WRAITH_CRT/$f" 2>/dev/null || true
    fi
  done
  for f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o; do
    [ -e "$gccdir/$f" ] && ln -sfn "$gccdir/$f" "$WRAITH_CRT/$f"
  done
  for f in ld-linux-x86-64.so.2 libpthread.a libpthread.so libdl.a libdl.so librt.a librt.so libutil.a libutil.so libm.a libm.so libc.a libc.so libresolv.a libresolv.so libgcc.a libgcc_s.so.1 libstdc++.so.6 libstdc++.a libatomic.so.1 libatomic.a; do
    [ -e "/usr/lib/$f" ] && ln -sfn "/usr/lib/$f" "$WRAITH_CRT/$f"
  done
  {
    echo "include_dir=/usr/include"
    echo "sys_include_dir=/usr/include"
    echo "crt_dir=$WRAITH_CRT"
    echo "msvc_lib_dir="
    echo "kernel32_lib_dir="
    echo "gcc_dir="
  } > "$WRAITH_LIBC"
  echo "sanitized CRT ready: $WRAITH_CRT"
}

ensure_blueprint() {
  command -v blueprint-compiler >/dev/null && return 0
  if pip3 install --user blueprint-compiler; then return 0; fi
  echo "pip install failed; falling back to manual wheel install (user-local)"
  local tmp url sp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  url="$(curl -s https://pypi.org/pypi/blueprint-compiler/json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([f["url"] for f in d["urls"] if f["packagetype"]=="bdist_wheel"][0])')"
  [ -n "$url" ] || return 1
  curl -sfL "$url" -o "$tmp/bp.whl" || return 1
  sp="$(python3 -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$sp" "$HOME/.local/bin" "$HOME/.local/share/pkgconfig"
  python3 -m zipfile -e "$tmp/bp.whl" "$tmp/bpx"
  cp -r "$tmp/bpx/blueprintcompiler" "$sp/"
  cp -r "$tmp/bpx"/blueprint_compiler-*.dist-info "$sp/"
  printf '#!/usr/bin/env python3\nimport sys\nfrom blueprintcompiler.main import main\nsys.exit(main())\n' > "$HOME/.local/bin/blueprint-compiler"
  chmod +x "$HOME/.local/bin/blueprint-compiler"
  cp "$tmp/bpx"/blueprint_compiler-*.data/data/share/pkgconfig/blueprint-compiler.pc "$HOME/.local/share/pkgconfig/"
}

if [ "${1:-}" = "--setup" ]; then
  [ -x "$WRAITH_ZIG/zig" ] || { echo "Zig missing at $WRAITH_ZIG — see ADR-001"; exit 1; }
  ensure_blueprint
  if command -v rpm >/dev/null 2>&1; then
    [ -f "$WRAITH_SYS/usr/include/libadwaita-1/adwaita.h" ] || setup_sysroot
  else
    { [ -f "$WRAITH_CRT/crt1.o" ] && [ -f "$WRAITH_LIBC" ]; } || setup_sanitized_crt
  fi
fi

export PATH="$WRAITH_ZIG:$HOME/.local/bin:$PATH"
export PKG_CONFIG_PATH="$WRAITH_SYS/usr/lib64/pkgconfig:/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:$HOME/.local/share/pkgconfig"
export LIBRARY_PATH="$WRAITH_SYS/usr/lib64"
if [ -f "$WRAITH_LIBC" ]; then
  export ZIG_LIBC="$WRAITH_LIBC"
fi
echo "wraith build env: zig=$(zig version 2>/dev/null) sysroot=$WRAITH_SYS"
