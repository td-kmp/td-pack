# shellcheck shell=bash
# Prelink: TDLib + OpenSSL + zlib → one relocatable object exporting only the
# tdjson C API (td/tdclientjson_export_list).
#
# The linker runs LTO over the whole bitcode program with every non-API symbol
# internalized, so unreachable code is deleted before shipping. The result is
# close to the size of libtdjson.so but is still a plain static archive, which
# is the only kind of binary a Kotlin/Native klib can carry (K/N's linker keeps
# just *.a / *.lib from a klib's `included/` dir and silently drops the rest).

export_symbols() {
  # tdclientjson_export_list uses Mach-O names (leading underscore).
  sed -e 's/[[:space:]]*$//' -e '/^$/d' "$TD_DIR/tdclientjson_export_list"
}

td_archives() {
  find "$BUILD_ROOT/td" -name '*.a' -not -path '*/CMakeFiles/*' | sort
}

prelink() {
  banner "Prelink — $TARGET"
  local work="$BUILD_ROOT/prelink"
  rm -rf "$work"; mkdir -p "$work"

  local archives=()
  while IFS= read -r a; do archives+=("$a"); done < <(td_archives)
  archives+=("$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libz.a")
  info "Inputs: ${#archives[@]} archives"

  case "$FAMILY" in
    apple) prelink_macho "$work" "${archives[@]}" ;;
    linux) prelink_elf "$work" "${archives[@]}" ;;
    mingw) prelink_coff "$work" "${archives[@]}" ;;
  esac

  mkdir -p "$OUT_DIR/lib"
  make_archive "$OUT_DIR/lib/libtdjson.a" "$work/tdjson.o"
  success "libtdjson.a: $(du -h "$OUT_DIR/lib/libtdjson.a" | cut -f1)"
}

prelink_macho() {
  local work="$1"; shift
  export_symbols > "$work/exports.txt"
  local roots=()
  while IFS= read -r s; do roots+=(-u "$s"); done < "$work/exports.txt"

  # -u roots pull in only the archive members the API reaches; the exported
  # list makes ld64 hand libLTO everything else as internal.
  run_logged "$work/ld.log" xcrun ld -r \
    -arch "$APPLE_ARCH" \
    -platform_version "$APPLE_PLATFORM" "$APPLE_MIN" "$SDK_VERSION" \
    -syslibroot "$SDK_PATH" \
    -exported_symbols_list "$work/exports.txt" \
    ${TDPACK_LTO_FLAGS:-} \
    "${roots[@]}" \
    "$@" \
    -o "$work/tdjson.full.o"

  # Drop local symbols and debug info: the consumer links against the
  # exported API only.
  run_logged "$work/strip.log" xcrun strip -x -S "$work/tdjson.full.o" -o "$work/tdjson.o"
}

# ── ELF / COFF ────────────────────────────────────────────────────────────────
# lld cannot internalize during `-r`, so let it run a *shared-library* LTO link
# instead, where a version script / .def file exports only the API and all
# other symbols are internalized and dead-stripped, and have it stop right
# after optimization (--lto-emit-llvm). That single optimized module is then
# compiled to one object. lld resolves archive members exactly as in a real
# link, so duplicate or unused members are never a problem.

api_symbols() { export_symbols | sed 's/^_//'; }

lto_emit_module() {
  local work="$1"; shift
  local roots=()
  while IFS= read -r s; do roots+=(-u "$s"); done < <(api_symbols)
  local emit=--lto-emit-llvm
  [[ "$FAMILY" == mingw ]] && emit=-plugin-opt=emit-llvm   # MinGW driver spelling
  run_logged "$work/lto.log" "$LLVM_BIN/ld.lld" "$@" "${roots[@]}" \
    "$emit" -o "$work/merged.bc"
  run_logged "$work/comdat.log" strip_internal_comdats "$work/merged.bc" "$work/merged.flat.bc"
  # shellcheck disable=SC2086
  run_logged "$work/codegen.log" "$CC_BIN" $TARGET_CFLAGS -Os -c "$work/merged.flat.bc" -o "$work/merged.o"
}

# After internalization ~50k inline functions are internal but still carry
# their COMDATs, and each COMDAT becomes its own section (+ .pdata/.xdata on
# COFF): ~145k sections, a third of the object. In a single module a COMDAT on
# an internal symbol has nothing to deduplicate against, so drop them in the
# IR. Refuses to touch a COMDAT on anything with external linkage.
strip_internal_comdats() {
  "$LLVM_BIN/llvm-dis" "$1" -o - | perl -ne '
    next if /^\$(?:"[^"]*"|\S+) = comdat \w+$/;
    if (/^(?:define|@)/ && / comdat\b/) {
      die "external symbol in a COMDAT: $_"
        unless /^define (?:internal|private)\b/ || /^@(?:"[^"]*"|\S+) = (?:internal|private)\b/;
      s/,? comdat(?:\(\$(?:"[^"]*"|[^)]*)\))?(?=[ ,]|$)//g;
    }
    print' | "$LLVM_BIN/llvm-as" -o "$2"
}

# Native (non-bitcode) archive members: OpenSSL's hand-written asm.
collect_native_members() {
  local out="$1"; shift
  local dir; dir="$(dirname "$out")/native-members"
  rm -rf "$dir"; mkdir -p "$dir"
  local a m objs=()
  for a in "$@"; do
    while IFS= read -r m; do
      # LLVM bitcode starts with 'BC' 0xC0DE; everything else is native code.
      if [[ "$("$LLVM_BIN/llvm-ar" p "$a" "$m" | head -c 2)" != "BC" ]]; then
        (cd "$dir" && "$LLVM_BIN/llvm-ar" x "$a" "$m")
        objs+=("$dir/$m")
      fi
    done < <("$LLVM_BIN/llvm-ar" t "$a")
  done
  rm -f "$out"
  [[ ${#objs[@]} -gt 0 ]] && "$LLVM_BIN/llvm-ar" qcs "$out" "${objs[@]}"
  return 0
}

prelink_elf() {
  local work="$1"; shift
  { echo "{ global:"; api_symbols | sed 's/$/;/'; echo "local: *; };"; } > "$work/api.map"
  api_symbols > "$work/api.txt"

  lto_emit_module "$work" -m "$LLD_EMULATION" -shared --version-script="$work/api.map" "$@"

  # Re-attach the asm objects the module still calls into. Their symbols were
  # kept global by LTO (referenced from native code), so localize everything
  # but the API afterwards; --strip-unneeded then drops the now-unused names.
  # No --gc-sections: with -r it would also drop .eh_frame.
  collect_native_members "$work/native.a" "$@"
  local roots=()
  while IFS= read -r s; do roots+=(-u "$s"); done < "$work/api.txt"
  local native=()
  [[ -f "$work/native.a" ]] && native=("$work/native.a")
  run_logged "$work/ld-r.log" "$LLVM_BIN/ld.lld" -m "$LLD_EMULATION" -r \
    "${roots[@]}" \
    "$work/merged.o" ${native[@]+"${native[@]}"} -o "$work/combined.o"
  # COMMON symbols (OpenSSL asm's OPENSSL_ia32cap_P) must stay global: lld has
  # no --define-common for -r, and a localized common turns into an absolute
  # symbol the consumer cannot relocate against. The consumer's link allocates it.
  { cat "$work/api.txt"; "$LLVM_BIN/llvm-nm" "$work/combined.o" | awk '$2 == "C" { print $3 }'; } \
    > "$work/keep.txt"
  run_logged "$work/objcopy.log" "$LLVM_BIN/llvm-objcopy" \
    --keep-global-symbols="$work/keep.txt" --strip-unneeded \
    "$work/combined.o" "$work/tdjson.o"
}

prelink_coff() {
  local work="$1"; shift
  # MinGW lld auto-exports every symbol of a DLL unless told otherwise.
  # CRT/Win32 imports and the DLL entry point stay unresolved here; the
  # consumer's link resolves them (-force:unresolved/-noentry go straight to
  # the COFF driver, the MinGW one has no spelling for them).
  { echo "EXPORTS"; api_symbols; } > "$work/api.def"
  lto_emit_module "$work" -m "$LLD_EMULATION" -shared --exclude-all-symbols \
    -Xlink=-force:unresolved -Xlink=-noentry "$work/api.def" "$@"
  run_logged "$work/objcopy.log" "$LLVM_BIN/llvm-objcopy" --strip-debug \
    "$work/merged.o" "$work/tdjson.o"
}
