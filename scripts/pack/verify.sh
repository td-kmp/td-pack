# shellcheck shell=bash
# Verify the packaged archive the way the consumer will use it:
#   1. link tests/smoke.c against libtdjson.a with plain clang (catches missing
#      symbols with a readable error) and run it when the host can;
#   2. cinterop → klib → konanc program, run when the host can;
#   3. with TDPACK_NETWORK_TEST=1, tests/network.c against Telegram's test DC.
# Also reports the klib size, which is what ends up on Maven Central.

# A hung emulated program (QEMU, wine) must fail the step, not stall the job.
# Prints a "timeout <secs>" prefix where coreutils' timeout exists.
timeout_prefix() {
  command -v timeout &>/dev/null && echo "timeout ${TDPACK_RUN_TIMEOUT:-900}"
  return 0
}

# Builds (once per Dockerfile version) and prints the wine test image.
wine_image() {
  command -v docker &>/dev/null && docker info &>/dev/null || return 1
  local file="$PROJECT_ROOT/tests/docker/wine.Dockerfile"
  local tag; tag="tdpack-wine:$(shasum -a 256 "$file" | cut -c1-12)"
  docker image inspect "$tag" &>/dev/null \
    || docker build -q --platform linux/amd64 -t "$tag" -f "$file" "$(dirname "$file")" >&2 \
    || return 1
  echo "$tag"
}

# Prints the command prefix that runs a target binary on this host, or fails
# when it cannot be run here (then only linking is verified).
#   iOS simulator: set TDPACK_SIM_DEVICE to a booted simulator UDID.
#   MinGW on a non-Windows host: wine in Docker (tests/docker/wine.Dockerfile).
#   Linux on a non-Linux host: Docker, in the oldest distro that meets the
#   K/N sysroot's glibc baseline (x64: 2.19 → ubuntu:16.04 / 2.23,
#   arm64: 2.25 → ubuntu:18.04 / 2.27), to prove the baseline holds.
target_runner() {
  case "$TARGET" in
    macosArm64)
      [[ "$(uname -sm)" == "Darwin arm64" ]] && echo "env" ;;
    macosX64)
      arch -x86_64 /usr/bin/true 2>/dev/null && echo "arch -x86_64" ;;
    iosSimulatorArm64)
      [[ -n "${TDPACK_SIM_DEVICE:-}" && "$(uname -sm)" == "Darwin arm64" ]] \
        && echo "xcrun simctl spawn $TDPACK_SIM_DEVICE" ;;
    linuxX64|linuxArm64)
      local arch; arch=$([[ "$TARGET" == linuxX64 ]] && echo x86_64 || echo aarch64)
      if [[ "$(uname -sm)" == "Linux $arch" ]]; then
        echo "env"
      elif command -v docker &>/dev/null && docker info &>/dev/null; then
        local platform image
        if [[ "$TARGET" == linuxX64 ]]; then platform=linux/amd64; image=ubuntu:16.04
        else platform=linux/arm64; image=ubuntu:18.04; fi
        echo "$(timeout_prefix) docker run --rm --platform $platform -v $BUILD_ROOT/verify:$BUILD_ROOT/verify $image"
      else
        return 1
      fi ;;
    mingwX64)
      if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
        echo "env"
      elif wine_image >/dev/null; then
        echo "$(timeout_prefix) docker run --rm --platform linux/amd64 -v $BUILD_ROOT/verify:$BUILD_ROOT/verify $(wine_image) wine"
      else
        return 1
      fi ;;
    *) return 1 ;;
  esac
}

verify() {
  banner "Verify — $TARGET"
  local work="$BUILD_ROOT/verify"
  rm -rf "$work"; mkdir -p "$work"

  local linker_opts
  linker_opts="$(sed -n 's/^linkerOpts=//p' "$OUT_DIR/tdlib.properties")"

  # 1. Plain C link. -lc++ mirrors what K/N links on Apple targets.
  # The runtime libraries mirror what K/N links for the target
  # (konan.properties: linkerKonanFlags.*).
  local runtime
  case "$FAMILY" in
    apple) runtime="-lc++" ;;
    linux) runtime="-fuse-ld=lld -static-libstdc++ -lpthread -ldl -lm" ;;
    mingw) runtime="-fuse-ld=lld -static-libstdc++ -static-libgcc -lbcrypt
                    -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic" ;;
  esac
  # shellcheck disable=SC2086
  run_logged "$work/smoke-link.log" "$CXX_BIN" $TARGET_CFLAGS -x c "$PROJECT_ROOT/tests/smoke.c" -x none \
    -I"$OUT_DIR/include" "$OUT_DIR/lib/libtdjson.a" $linker_opts $runtime -o "$work/smoke"
  success "C smoke test links"
  local exe=""; [[ "$FAMILY" == mingw ]] && exe=".exe"
  local kexe=".kexe"; [[ "$FAMILY" == mingw ]] && kexe=".exe"
  local runner=""
  runner="$(target_runner)" || true
  if [[ -n "$runner" ]]; then
    # shellcheck disable=SC2086
    run_logged "$work/smoke-run.log" $runner "$work/smoke$exe"
    success "C smoke test runs: $(tail -1 "$work/smoke-run.log" | cut -c1-100)"
    # Opt-in (needs network): full MTProto handshake against the test DC.
    if [[ "${TDPACK_NETWORK_TEST:-0}" == 1 ]]; then
      # shellcheck disable=SC2086
      run_logged "$work/network-link.log" "$CXX_BIN" $TARGET_CFLAGS -x c "$PROJECT_ROOT/tests/network.c" -x none \
        -I"$OUT_DIR/include" "$OUT_DIR/lib/libtdjson.a" $linker_opts $runtime -o "$work/network"
      rm -rf "$work/network-db"
      # shellcheck disable=SC2086
      run_logged "$work/network-run.log" $runner "$work/network$exe" "$work/network-db"
      success "Network test (test DC handshake): $(grep -o '"message":"[A-Z_]*"' "$work/network-run.log")"
    fi
  fi

  # 2. Kotlin/Native, exactly like the consumer's cinterop.
  ensure_konan
  local kt; kt="$(konan_target "$TARGET")"
  cat > "$work/tdjson.def" <<EOF
headers = td/telegram/td_json_client.h td/telegram/td_log.h
headerFilter = td/telegram/*
staticLibraries = libtdjson.a
linkerOpts = $linker_opts
EOF
  run_logged "$work/cinterop.log" "$KONAN_HOME/bin/cinterop" -def "$work/tdjson.def" -pkg tdjson \
    -target "$kt" -compiler-option "-I$OUT_DIR/include" -libraryPath "$OUT_DIR/lib" \
    -o "$work/tdjson"
  run_logged "$work/konanc.log" "$KONAN_HOME/bin/konanc" -target "$kt" -opt \
    "$PROJECT_ROOT/tests/kn/main.kt" -l "$work/tdjson.klib" -o "$work/kn-smoke"
  success "klib: $(du -h "$work/tdjson.klib" | cut -f1), K/N binary links"
  if [[ -n "$runner" ]]; then
    # shellcheck disable=SC2086
    run_logged "$work/kn-run.log" $runner "$work/kn-smoke$kexe"
    success "K/N smoke test runs: $(tail -1 "$work/kn-run.log" | cut -c1-100)"
  fi
}
