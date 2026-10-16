# shellcheck shell=bash
# TDLib itself: only the tdjson_static target and its dependency archives.
# Objects are LTO bitcode; prelink turns them into a single native object.

# Host-side code generation (TL schemes, MIME tables) into td's source tree.
# Cross builds skip td's generators and expect these files to exist. The
# output is target-independent, so it runs once per checkout; td's own
# TD_GENERATE_SOURCE_FILES mode needs neither OpenSSL nor zlib.
codegen() {
  banner "TDLib code generation (host)"
  local build="$PROJECT_ROOT/build/host-codegen"
  local stamp="$build/.done-$(git -C "$TD_DIR" rev-parse HEAD)"
  if [[ -f "$stamp" ]]; then
    info "Already generated for this td commit, skipping"; return 0
  fi
  # shellcheck disable=SC2046
  run_logged "$build/configure.log" cmake -S "$TD_DIR" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DTD_GENERATE_SOURCE_FILES=ON $(launcher_args)
  run_progress "$build/build.log" "codegen" ninja cmake --build "$build" -j"$NPROC"
  rm -f "$build"/.done-*; touch "$stamp"
  success "Generated sources ready"
}

build_tdlib() {
  banner "TDLib — $TARGET"
  local build="$BUILD_ROOT/td"
  local args=(
    -S "$TD_DIR" -B "$build" -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    # Replace (not append to) the per-config flags so -O3 never sneaks in.
    "-DCMAKE_C_FLAGS_RELEASE=$OPT_FLAGS"
    "-DCMAKE_CXX_FLAGS_RELEASE=$OPT_FLAGS"
    -DTD_ENABLE_JNI=OFF
    -DTD_ENABLE_DOTNET=OFF
    -DTD_ENABLE_LTO=OFF            # we drive LTO ourselves via OPT_FLAGS
    -DBUILD_TESTING=OFF
    # td's own ccache hook also wraps link/archive rules (breaks MinGW's);
    # ccache is applied via CMAKE_<LANG>_COMPILER_LAUNCHER instead.
    -DCCACHE_FOUND=OFF
    # Explicit paths: cross toolchains confine find_package() to the sysroot,
    # and on Linux hosts it must never pick up the host's libssl/libz.
    -DOPENSSL_INCLUDE_DIR="$PREFIX/include"
    -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a"
    -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a"
    -DZLIB_INCLUDE_DIR="$ZLIB_INC"
    -DZLIB_LIBRARY="$ZLIB_LIB"
  )
  # shellcheck disable=SC2207
  args+=($(launcher_args))

  case "$FAMILY" in
    apple)
      args+=(
        -DCMAKE_C_COMPILER="$CC_BIN"
        -DCMAKE_CXX_COMPILER="$CXX_BIN"
        -DCMAKE_OSX_SYSROOT="$SDK_PATH"
        -DCMAKE_OSX_ARCHITECTURES="$APPLE_ARCH"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$APPLE_MIN"
        # Always set: makes CMake treat every target (even the host's own
        # arch) as a cross build, so td uses the codegen step's sources
        # instead of building generators for the target and running them.
        -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM"
        -DCMAKE_SYSTEM_PROCESSOR="$APPLE_ARCH"
      )
      ;;
    linux|mingw)
      args+=(
        -DCMAKE_TOOLCHAIN_FILE="$PROJECT_ROOT/cmake/konan-toolchain.cmake"
        -DTDPACK_LLVM_BIN="$LLVM_BIN"
        -DTDPACK_TRIPLE="$TRIPLE"
        -DTDPACK_SYSROOT="$SYSROOT"
        -DTDPACK_GCC_TOOLCHAIN="$GCC_TOOLCHAIN"
        -DTDPACK_SYSTEM="$CMAKE_SYSTEM"
        -DTDPACK_PROCESSOR="$CMAKE_PROCESSOR"
        -DTDPACK_PREFIX="$PREFIX"
      )
      # td adds -Wl,--exclude-libs,ALL to every link, which MinGW lld rejects,
      # so its link-based atomics probe fails. x86_64 atomics are always
      # lock-free; skip the probe instead of patching td.
      [[ "$FAMILY" == mingw ]] && args+=(-DATOMICS_FOUND=TRUE -DATOMICS_LIBRARIES=)
      ;;
    android)
      args+=(
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="$ANDROID_ABI"
        -DANDROID_PLATFORM="android-$ANDROID_API"
        -DANDROID_STL=c++_static
      )
      ;;
  esac

  run_logged "$BUILD_ROOT/logs/td-configure.log" cmake "${args[@]}"
  info "Building tdjson_static (log: $BUILD_ROOT/logs/td-build.log)"
  run_progress "$BUILD_ROOT/logs/td-build.log" "tdlib" ninja \
    cmake --build "$build" --target tdjson_static -j"$NPROC"
  success "TDLib archives → $build"
}
