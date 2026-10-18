# shellcheck shell=bash
# zlib, compiled straight from its sources (no configure/CMake): the same
# recipe works for every target, and the objects become LTO bitcode that
# prelink folds into libtdjson.a — the consumer never needs -lz.

build_zlib() {
  banner "zlib $ZLIB_VERSION — $TARGET"
  if [[ "$FAMILY" == android ]]; then
    info "Android: using the system libz"; return 0
  fi
  if [[ "$FAMILY" == emscripten ]]; then
    info "Web: using Emscripten's zlib port"; return 0
  fi
  if [[ -f "$PREFIX/lib/libz.a" ]]; then
    info "Already built, skipping"; return 0
  fi

  local tarball work src
  tarball="$(fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz")"
  work="$BUILD_ROOT/zlib"
  rm -rf "$work"; mkdir -p "$work/obj" "$PREFIX/lib" "$PREFIX/include"
  tar -xzf "$tarball" -C "$work"
  src="$work/zlib-${ZLIB_VERSION}"

  local f objs=()
  for f in adler32 compress crc32 deflate gzclose gzlib gzread gzwrite \
           infback inffast inflate inftrees trees uncompr zutil; do
    # shellcheck disable=SC2086
    "$CC_BIN" $TARGET_CFLAGS $OPT_FLAGS -DHAVE_UNISTD_H -DHAVE_STDARG_H \
      -c "$src/$f.c" -o "$work/obj/$f.o"
    objs+=("$work/obj/$f.o")
  done
  make_archive "$PREFIX/lib/libz.a" "${objs[@]}"
  cp "$src/zlib.h" "$src/zconf.h" "$PREFIX/include/"
  success "zlib → $PREFIX/lib/libz.a"
}
