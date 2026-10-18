# shellcheck shell=bash
# OpenSSL, trimmed to what TDLib actually calls.
#
# td uses: AES (ECB/CBC/CTR + low-level AES_*), SHA-1/256/512, MD5, HMAC,
# PBKDF2, RSA (OAEP + legacy RSA_* API), BN, X25519/Ed25519 via EVP (needs
# `ec`), TLS client with X509 verification, PEM, and CA loading from files.
# Everything else is switched off at configure time: the provider dispatch
# tables reference every enabled algorithm, so dead-code elimination in
# prelink cannot drop them — only configure can.

OPENSSL_DISABLE=(
  no-shared no-module no-dso no-engine no-legacy no-apps no-docs no-tests
  no-ui-console no-autoload-config no-comp no-zlib
  no-ssl3 no-dtls no-srp no-srtp no-sctp no-quic no-psk no-nextprotoneg
  no-cms no-ts no-ocsp no-ct no-cmp no-http no-ssl-trace
  no-idea no-seed no-camellia no-aria no-sm2 no-sm3 no-sm4 no-rc2 no-rc4 no-rc5
  no-md2 no-md4 no-mdc2 no-whirlpool no-rmd160 no-cast no-bf no-des
  no-siphash no-scrypt no-argon2 no-gost no-ec2m no-dsa no-ocb
)

openssl_configure_target() {
  case "$TARGET" in
    macosArm64)        echo darwin64-arm64-cc ;;
    macosX64)          echo darwin64-x86_64-cc ;;
    iosArm64)          echo ios64-xcrun ;;
    iosSimulatorArm64) echo iossimulator-arm64-xcrun ;;
    iosX64)            echo iossimulator-x86_64-xcrun ;;
    linuxX64)          echo linux-x86_64-clang ;;
    linuxArm64)        echo linux-aarch64 ;;
    mingwX64)          echo mingw64 ;;
    mingwArm64)        echo tdpack-mingw-arm64 ;;   # scripts/pack/openssl-targets.conf
    androidArm64) echo android-arm64 ;;
    androidArm32) echo android-arm ;;
    androidX64)  echo android-x86_64 ;;
    androidX86)  echo android-x86 ;;
    web)         echo linux-generic32 ;;
    *) error "No OpenSSL configure target for $TARGET" ;;
  esac
}

build_openssl() {
  banner "OpenSSL $OPENSSL_VERSION — $TARGET"
  if [[ -f "$PREFIX/lib/libcrypto.a" && -f "$PREFIX/lib/libssl.a" ]]; then
    info "Already built, skipping"; return 0
  fi

  local tarball work src
  tarball="$(fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz")"
  work="$BUILD_ROOT/openssl"
  rm -rf "$work"; mkdir -p "$work"
  tar -xzf "$tarball" -C "$work"
  src="$work/openssl-${OPENSSL_VERSION}"

  pushd "$src" >/dev/null
  # CC carries the full target triple + sysroot, so the configure target only
  # selects OpenSSL's asm flavour. Asm objects stay native code; prelink links
  # them next to the LTO bitcode.
  # ccache too (OpenSSL's make does not go through CMake's launcher). Android's
  # configs replace CC with the NDK wrapper by name, so it stays plain there.
  local cc="$CC_BIN $TARGET_CFLAGS"
  command -v ccache &>/dev/null && [[ "$FAMILY" != android ]] && cc="ccache $cc"
  local env_args=(CC="$cc") extra=()
  if [[ "$FAMILY" != apple ]]; then
    env_args+=(AR="$LLVM_BIN/llvm-ar" RANLIB="$LLVM_BIN/llvm-ranlib")
  fi
  # MinGW has no relocatable link (lld's COFF port lacks -r), so prelink needs
  # the whole library as bitcode: no hand-written asm there.
  [[ "$FAMILY" == mingw ]] && extra+=(no-asm)
  [[ "$TARGET" == mingwArm64 ]] && extra+=(--config="$PROJECT_ROOT/scripts/pack/openssl-targets.conf")
  # Web: no threads (td's Emscripten build is single-threaded), no native asm.
  [[ "$FAMILY" == emscripten ]] && extra+=(no-asm no-threads no-secure-memory)
  if [[ "$FAMILY" == android ]]; then
    # OpenSSL's android-* targets locate the NDK themselves.
    env_args+=(ANDROID_NDK_ROOT="$ANDROID_NDK" PATH="$LLVM_BIN:$PATH")
    extra+=(-D__ANDROID_API__="$ANDROID_API")
  fi
  # shellcheck disable=SC2086
  run_logged "$work/configure.log" env "${env_args[@]}" \
    ./Configure "$(openssl_configure_target)" "${OPENSSL_DISABLE[@]}" ${extra[@]+"${extra[@]}"} \
      --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
      $OPT_FLAGS -DOPENSSL_SMALL_FOOTPRINT
  # Android's configs call the NDK's <triple><api>-clang wrappers by name.
  local make_env=(env)
  [[ "$FAMILY" == android ]] && make_env+=(PATH="$LLVM_BIN:$PATH")
  # Progress = compiled objects out of what a dry run says will be compiled.
  local re=' -c -o [^ ]+\.o( |$)' total
  total="$("${make_env[@]}" make -n build_libs 2>/dev/null | grep -cE -- "$re" || true)"
  run_progress "$work/build.log" "openssl" "count:$total:$re" "${make_env[@]}" make -j"$NPROC" build_libs
  run_logged "$work/install.log" "${make_env[@]}" make install_dev
  popd >/dev/null
  rm -rf "$src"
  success "OpenSSL → $PREFIX/lib/{libcrypto,libssl}.a"
}
