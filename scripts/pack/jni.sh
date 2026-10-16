# shellcheck shell=bash
# JNI shared library (libtdjsonjava) for the JVM and Android.
#
# Built from the same LTO bitcode archives as the static archive, in one
# whole-program link that exports only JNI_OnLoad (natives are bound with
# RegisterNatives), so everything else is internalized and dead-stripped.
# The C++ runtime is linked statically: the library only depends on the OS.
#
# Java side expected by td_jni.cpp (patches/native-bridge-jni.patch):
#   package io.xbot.tdlib
#   class NativeBridge {
#     static native int    nativeCreateClientId();
#     static native void   nativeSend(int clientId, String request);
#     static native String nativeReceive(double timeout);
#     static native String nativeExecute(String request);
#     static native void   nativeSetLogMessageHandler(int maxVerbosityLevel, LogMessageHandler handler);
#     interface LogMessageHandler { void onLogMessage(int verbosityLevel, String message); }
#   }

JNI_PACKAGE="io/xbot/tdlib"

# Release asset suffix, named like the JVM sees the platform (os-arch, as skiko
# does); Android by ABI, i.e. the jniLibs/<abi> directory it goes into.
jni_artifact_name() {
  case "$TARGET" in
    macosArm64) echo macos-arm64 ;;
    macosX64)   echo macos-x64 ;;
    linuxX64)   echo linux-x64 ;;
    linuxArm64) echo linux-arm64 ;;
    mingwX64)   echo windows-x64 ;;
    mingwArm64) echo windows-arm64 ;;
    android*)   echo "android-$ANDROID_ABI" ;;
    *) error "No JNI library for $TARGET" ;;
  esac
}

jni_library_name() {
  case "$FAMILY" in
    apple) echo libtdjsonjava.dylib ;;
    mingw) echo tdjsonjava.dll ;;
    *)     echo libtdjsonjava.so ;;
  esac
}

# Sets JDK_HOME to a full JDK (jni.h + javac). JAVA_HOME may point at a JRE
# without headers (e.g. Android Studio's bundled JBR), so try a few places.
find_jdk() {
  local candidates=("${JAVA_HOME:-}" "$(/usr/libexec/java_home 2>/dev/null || true)")
  local d
  for d in /opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home \
           /usr/local/opt/openjdk*/libexec/openjdk.jdk/Contents/Home /usr/lib/jvm/*; do
    candidates+=("$d")
  done
  for d in "${candidates[@]}"; do
    if [[ -n "$d" && -f "$d/include/jni.h" && -x "$d/bin/javac" ]]; then
      JDK_HOME="$d"; return 0
    fi
  done
  error "No JDK with JNI headers found (set JAVA_HOME to a full JDK)"
}

# Sets JNI_INCLUDES (array: JDK paths may contain spaces).
jni_include_flags() {
  JNI_INCLUDES=()
  # Android's NDK sysroot ships a self-contained jni.h.
  [[ "$FAMILY" == android ]] && return 0
  find_jdk
  # Our jni_md.h first: the host JDK's one is for the host OS, not the target.
  JNI_INCLUDES=("-I$PROJECT_ROOT/jni/include" "-I$JDK_HOME/include")
}

build_jni() {
  banner "JNI library — $TARGET"
  local work="$BUILD_ROOT/jni" td_build="$BUILD_ROOT/td"
  rm -rf "$work"; mkdir -p "$work"
  [[ -d "$td_build" ]] || error "Run the tdlib step first"

  # Patch a copy, never the submodule.
  run_logged "$work/patch.log" patch -s -o "$work/td_jni.cpp" \
    "$TD_DIR/example/java/td_jni.cpp" "$PROJECT_ROOT/patches/native-bridge-jni.patch"

  local defs=(-DTD_JSON_JAVA=1 "-DPACKAGE_NAME=\"$JNI_PACKAGE\"" -DTDJSON_STATIC_DEFINE)
  # Same Win32 API level/macros td itself compiles with (TdSetUpCompiler.cmake).
  [[ "$FAMILY" == mingw ]] && defs+=(-DNTDDI_VERSION=0x06020000 -DWINVER=0x0602 -D_WIN32_WINNT=0x0602
    -DPSAPI_VERSION=1 -DNOMINMAX -DUNICODE -D_UNICODE -DWIN32_LEAN_AND_MEAN)
  jni_include_flags
  local src
  for src in "$work/td_jni.cpp" "$TD_DIR/td/tl/tl_jni_object.cpp"; do
    # shellcheck disable=SC2086
    run_logged "$work/compile.log" "$CXX_BIN" $TARGET_CFLAGS $OPT_FLAGS \
      -std=c++17 -fno-exceptions -fno-rtti "${defs[@]}" ${JNI_INCLUDES[@]+"${JNI_INCLUDES[@]}"} \
      -I"$TD_DIR" -I"$TD_DIR/tdutils" -I"$td_build" -I"$td_build/tdutils" \
      -c "$src" -o "$work/$(basename "$src" .cpp).o"
  done

  local inputs=("$work/td_jni.o" "$work/tl_jni_object.o")
  while IFS= read -r a; do inputs+=("$a"); done < <(td_archives)
  inputs+=("$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a")
  # Android always has the system libz; elsewhere bundle ours.
  [[ "$FAMILY" == android ]] || inputs+=("$PREFIX/lib/libz.a")

  local out="$work/$(jni_library_name)" flags=()
  case "$FAMILY" in
    apple)
      flags=(-dynamiclib -install_name "@rpath/$(jni_library_name)"
             -Wl,-exported_symbol,_JNI_OnLoad -Wl,-dead_strip -Wl,-x -lc++) ;;
    linux|android)
      echo "{ global: JNI_OnLoad; local: *; };" > "$work/jni.map"
      flags=(-shared -fuse-ld=lld -Wl,--version-script="$work/jni.map"
             -Wl,--gc-sections -Wl,--icf=all -Wl,-O2 -Wl,-z,noexecstack -Wl,-z,relro -Wl,-z,now
             -static-libstdc++ -Wl,-s)
      if [[ "$FAMILY" == linux ]]; then
        flags+=(-static-libgcc -lpthread -ldl -lm)
      else
        # 16 KB pages: required by Android 15+ devices with 16 KB page size.
        flags+=(-Wl,-z,max-page-size=16384 -llog -lz)
      fi ;;
    mingw)
      { echo "EXPORTS"; echo "JNI_OnLoad"; } > "$work/jni.def"
      flags=(-shared -fuse-ld=lld "$work/jni.def" -Wl,--gc-sections -Wl,--icf=all -Wl,-s
             -static -static-libstdc++ -static-libgcc
             -lws2_32 -lmswsock -lnormaliz -lpsapi -lcrypt32 -lwinpthread) ;;
  esac
  # Full-LTO (ELF/COFF) codegen is single-threaded unless split into partitions.
  case "$FAMILY" in
    linux) flags+=(-Wl,--lto-partitions="$NPROC") ;;
    mingw) flags+=(-Wl,-Xlink=-opt:lldltopartitions="$NPROC") ;;
  esac
  # shellcheck disable=SC2086
  run_progress "$work/link.log" "jni (LTO link)" time "$CXX_BIN" $TARGET_CFLAGS $OPT_FLAGS "${inputs[@]}" "${flags[@]}" -o "$out"
  [[ "$FAMILY" == apple ]] && run_logged "$work/strip.log" xcrun strip -x "$out"

  local dest="$PROJECT_ROOT/out/jni-$(jni_artifact_name)"
  rm -rf "$dest"; mkdir -p "$dest/lib"
  cp "$out" "$dest/lib/"
  cat > "$dest/tdlib.properties" <<EOF
platform=$(jni_artifact_name)
tdlib.version=$(td_version)
tdlib.commit=$(git -C "$TD_DIR" rev-parse HEAD)
openssl.version=$OPENSSL_VERSION
library=$(jni_library_name)
jni.class=${JNI_PACKAGE//\//.}.NativeBridge
EOF
  [[ "$FAMILY" == android ]] && echo "android.abi=$ANDROID_ABI" >> "$dest/tdlib.properties"
  local archive="$PROJECT_ROOT/out/tdlib-jni-$(jni_artifact_name).tar.zst"
  tar -C "$dest" -cf - . | zstd -19 -T0 -q -f -o "$archive"
  success "$(jni_library_name): $(du -h "$out" | cut -f1), $(basename "$archive"): $(du -h "$archive" | cut -f1)"
}

# Checks the library's interface and dependencies, then runs tests/jni on a
# JVM where the host can: natively (macOS), in Docker (Linux), or on an
# Android device/emulator via dalvikvm (TDPACK_ANDROID_SERIAL=<adb serial>).
verify_jni() {
  banner "Verify JNI — $TARGET"
  local lib; lib="$PROJECT_ROOT/out/jni-$(jni_artifact_name)/lib/$(jni_library_name)"
  [[ -f "$lib" ]] || error "Run the jni step first"
  local work="$BUILD_ROOT/jni-verify"
  rm -rf "$work"; mkdir -p "$work/classes"

  # 1. Exports: JNI_OnLoad only.
  local exports
  case "$FAMILY" in
    apple) exports="$(xcrun nm -gU "$lib" | awk '{print $3}')" ;;
    mingw) exports="$("$LLVM_BIN/llvm-objdump" -p "$lib" | awk '/Ordinal +RVA +Name/ {f=1; next} f && NF==3 {print $3} f && NF==0 {f=0}')" ;;
    *)     exports="$("$LLVM_BIN/llvm-nm" -D --defined-only "$lib" | awk '{print $3}')" ;;
  esac
  [[ "$(echo "$exports" | sed 's/^_//' | sort -u | tr '\n' ' ')" == "JNI_OnLoad " ]] \
    || error "Unexpected exports: $(echo "$exports" | tr '\n' ' ')"

  # 2. Dependencies: OS libraries only (C++ runtime must be static).
  local deps allowed
  case "$FAMILY" in
    apple)   deps="$(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -v "$(jni_library_name)")"
             allowed='^/usr/lib/(libc\+\+\.1|libSystem\.B)\.dylib$' ;;
    linux)   deps="$("$LLVM_BIN/llvm-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
             allowed='^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux.*)$' ;;
    android) deps="$("$LLVM_BIN/llvm-readelf" -d "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
             allowed='^(libc|libm|libdl|liblog|libz)\.so$' ;;
    mingw)   deps="$("$LLVM_BIN/llvm-objdump" -p "$lib" | sed -n 's/^ *DLL Name: //p')"
             allowed='^(KERNEL32|USER32|ADVAPI32|SHELL32|WS2_32|MSWSOCK|NORMALIZ|PSAPI|CRYPT32|bcrypt|msvcrt|ucrtbase|api-ms-win-.*)\.dll$' ;;
  esac
  local bad; bad="$(echo "$deps" | grep -viE "$allowed" || true)"
  [[ -z "$bad" ]] || error "Unexpected dependencies: $(echo "$bad" | tr '\n' ' ')"
  success "Exports JNI_OnLoad only; depends on: $(echo "$deps" | xargs -n1 basename | tr '\n' ' ')"

  if [[ "$FAMILY" == android ]]; then
    local align
    align="$("$LLVM_BIN/llvm-readelf" -lW "$lib" | awk '$1 == "LOAD" {print $NF}' | sort -u | tr '\n' ' ')"
    [[ "$align" == "0x4000 " ]] || error "LOAD segments not 16 KB aligned: $align"
    success "16 KB page aligned"
  fi

  # 3. Run tests/jni.
  find_jdk
  run_logged "$work/javac.log" "$JDK_HOME/bin/javac" --release 8 -Xlint:-options -d "$work/classes" \
    "$PROJECT_ROOT/tests/jni/io/xbot/tdlib/NativeBridge.java" "$PROJECT_ROOT/tests/jni/JniSmoke.java"
  local run=()
  case "$TARGET" in
    macosArm64)
      [[ "$(uname -sm)" == "Darwin arm64" ]] && run=("$JDK_HOME/bin/java" -cp "$work/classes" JniSmoke "$lib") ;;
    linuxX64|linuxArm64)
      if command -v docker &>/dev/null && docker info &>/dev/null; then
        local platform; platform=$([[ "$TARGET" == linuxX64 ]] && echo linux/amd64 || echo linux/arm64)
        # shellcheck disable=SC2207
        run=($(timeout_prefix) docker run --rm --platform "$platform" -v "$work:$work" -v "$(dirname "$lib"):/jnilib"
             eclipse-temurin:21-jre java -cp "$work/classes" JniSmoke "/jnilib/$(jni_library_name)")
      fi ;;
    mingwX64)
      local image
      if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]] && image="$(wine_image)"; then
        # shellcheck disable=SC2207
        run=($(timeout_prefix) docker run --rm --platform linux/amd64 -v "$work:$work" -v "$(dirname "$lib"):/jnilib"
             "$image" wine /opt/jre/bin/java.exe -cp "Z:$work/classes" JniSmoke "Z:/jnilib/$(jni_library_name)")
      fi ;;
    android*)
      if [[ -n "${TDPACK_ANDROID_SERIAL:-}" ]]; then
        run_android_jni_smoke "$work" "$lib"; return 0
      fi ;;
  esac
  if [[ ${#run[@]} -gt 0 ]]; then
    # A JVM under wine (on a QEMU-emulated x86 host) occasionally dies inside
    # wine itself; give it one more try before calling it a failure.
    if [[ "$FAMILY" == mingw ]] && ! "${run[@]}" >"$work/run.log" 2>&1; then
      warn "Windows JVM under wine failed, retrying once"
    fi
    grep -q "log handler: ok" "$work/run.log" 2>/dev/null || run_progress "$work/run.log" "jni test" time "${run[@]}"
    success "Java smoke test runs: $(grep -c . "$work/run.log" >/dev/null; grep -o 'optionValueString.*' "$work/run.log" | cut -c1-60), $(tail -1 "$work/run.log")"
  else
    info "No JVM for $TARGET on this host: checked the library, not run"
  fi
}

# dalvikvm on a device/emulator: dex the test classes with d8, push, run.
run_android_jni_smoke() {
  local work="$1" lib="$2"
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  local d8; d8="$(ls -d "$sdk"/build-tools/*/d8 2>/dev/null | sort -V | tail -1)"
  [[ -x "$d8" ]] || error "d8 not found in $sdk/build-tools"
  local jar; jar="$(ls -d "$sdk"/platforms/android-*/android.jar | sort -V | tail -1)"
  (cd "$work/classes" && "$JDK_HOME/bin/jar" cf "$work/smoke.jar" .)
  run_logged "$work/d8.log" "$d8" --min-api 21 --lib "$jar" --output "$work" "$work/smoke.jar"
  local adb=(adb -s "$TDPACK_ANDROID_SERIAL") dir=/data/local/tmp/td-pack
  local abis; abis="$("${adb[@]}" shell getprop ro.product.cpu.abilist | tr -d '\r')"
  if [[ ",$abis," != *",$ANDROID_ABI,"* ]]; then
    info "$TDPACK_ANDROID_SERIAL runs $abis, not $ANDROID_ABI: checked the library, not run"
    return 0
  fi
  "${adb[@]}" shell "rm -rf $dir && mkdir -p $dir" >/dev/null
  "${adb[@]}" push "$work/classes.dex" "$lib" "$dir/" >/dev/null
  # Multilib images default dalvikvm to 64-bit, which cannot load a 32-bit .so.
  local vm
  case "$ANDROID_ABI" in armeabi-v7a|x86) vm=dalvikvm32 ;; *) vm=dalvikvm64 ;; esac
  run_logged "$work/run.log" "${adb[@]}" shell "VM=dalvikvm;
    for c in /apex/com.android.art/bin/$vm /system/bin/$vm; do [ -x \$c ] && VM=\$c && break; done;
    echo VM=\$VM; cd $dir && \$VM -cp classes.dex JniSmoke $dir/$(jni_library_name) && echo EXIT_OK"
  grep -q EXIT_OK "$work/run.log" || { tail -20 "$work/run.log" >&2; error "Android smoke test failed"; }
  success "Java smoke test runs on $TDPACK_ANDROID_SERIAL ($ANDROID_ABI): $(grep -o 'optionValueString[^,]*,[^,]*' "$work/run.log")"
}
