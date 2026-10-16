# shellcheck shell=bash
# Shared helpers and the per-target table for pack.sh.
#
# Targets are named exactly like Kotlin/Native Gradle targets (macosArm64,
# iosSimulatorArm64, linuxX64, mingwX64, ...) so the consumer project can map
# a KMP target to its archive without a lookup table.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}${BOLD}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}══ $* ${NC}"; }

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD_DIR="$PROJECT_ROOT/td"
SRC_CACHE="$PROJECT_ROOT/build/src"

# Pinned dependency versions. Bumping any of them invalidates CI caches.
ZLIB_VERSION="1.3.2"
OPENSSL_VERSION="3.5.9"   # LTS; td still uses the deprecated RSA_* API, so no 4.x

if command -v nproc &>/dev/null; then NPROC=$(nproc)
else NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4); fi

# Size-oriented codegen for everything that ends up in libtdjson.a. Code is
# emitted as LTO bitcode; real codegen happens once, in prelink, where the
# whole program is visible and everything but the public API is internalized.
# Apple: ld64 runs (Thin)LTO itself during `ld -r`. ELF/COFF: prelink merges
# everything into one LLVM module, which needs full-LTO bitcode.
# -Os over -Oz: -Oz shrinks the final app ~25% more but runs TDLib's JSON/text
# paths ~1.9x slower, and the klib itself does not get smaller.
OPT_FLAGS="${TDPACK_OPT_FLAGS:--Os -DNDEBUG}"

# ── Target table ──────────────────────────────────────────────────────────────
# Sets: FAMILY (apple|linux|mingw), TRIPLE, and family-specific variables.
#   apple: APPLE_SDK, APPLE_ARCH, APPLE_MIN, APPLE_PLATFORM (ld64 -platform_version),
#          CMAKE_SYSTEM (Darwin|iOS)
#   linux/mingw: KONAN_TARGET, CMAKE_SYSTEM (Linux|Windows), CMAKE_PROCESSOR,
#          LLD_EMULATION (ld.lld -m)
#   android: ANDROID_ABI
# and HAS_STATIC / HAS_JNI: which artifacts the target ships.
# Apple minimum versions match Kotlin/Native's konan.properties
# (minVersion.macos = 12.0, minVersion.ios = 15.0) so the consumer's K/N link
# never sees objects built for a newer OS than the Kotlin binary.
load_target() {
  TARGET="$1"
  case "$TARGET" in
    macosArm64)
      FAMILY=apple; APPLE_SDK=macosx; APPLE_ARCH=arm64; APPLE_MIN=12.0
      APPLE_PLATFORM=macos; CMAKE_SYSTEM=Darwin; TRIPLE=arm64-apple-macos12.0 ;;
    macosX64)
      FAMILY=apple; APPLE_SDK=macosx; APPLE_ARCH=x86_64; APPLE_MIN=12.0
      APPLE_PLATFORM=macos; CMAKE_SYSTEM=Darwin; TRIPLE=x86_64-apple-macos12.0 ;;
    iosArm64)
      FAMILY=apple; APPLE_SDK=iphoneos; APPLE_ARCH=arm64; APPLE_MIN=15.0
      APPLE_PLATFORM=ios; CMAKE_SYSTEM=iOS; TRIPLE=arm64-apple-ios15.0 ;;
    iosSimulatorArm64)
      FAMILY=apple; APPLE_SDK=iphonesimulator; APPLE_ARCH=arm64; APPLE_MIN=15.0
      APPLE_PLATFORM=ios-simulator; CMAKE_SYSTEM=iOS; TRIPLE=arm64-apple-ios15.0-simulator ;;
    iosX64)
      FAMILY=apple; APPLE_SDK=iphonesimulator; APPLE_ARCH=x86_64; APPLE_MIN=15.0
      APPLE_PLATFORM=ios-simulator; CMAKE_SYSTEM=iOS; TRIPLE=x86_64-apple-ios15.0-simulator ;;
    linuxX64)
      FAMILY=linux; KONAN_TARGET=linux_x64; TRIPLE=x86_64-unknown-linux-gnu; LLD_EMULATION=elf_x86_64
      CMAKE_SYSTEM=Linux; CMAKE_PROCESSOR=x86_64 ;;
    linuxArm64)
      FAMILY=linux; KONAN_TARGET=linux_arm64; TRIPLE=aarch64-unknown-linux-gnu; LLD_EMULATION=aarch64linux
      CMAKE_SYSTEM=Linux; CMAKE_PROCESSOR=aarch64 ;;
    mingwX64)
      FAMILY=mingw; KONAN_TARGET=mingw_x64; TRIPLE=x86_64-w64-windows-gnu; LLD_EMULATION=i386pep
      CMAKE_SYSTEM=Windows; CMAKE_PROCESSOR=x86_64 ;;
    # JNI-only targets (no Kotlin/Native target exists or is needed for them).
    mingwArm64)
      # Windows on ARM JVMs. Not a K/N target, so no K/N sysroot either:
      # built with llvm-mingw (libc++, UCRT), all linked into the DLL.
      FAMILY=mingw; KONAN_TARGET=""; TRIPLE=aarch64-w64-mingw32; LLD_EMULATION=arm64pe
      CMAKE_SYSTEM=Windows; CMAKE_PROCESSOR=aarch64 ;;
    androidArm64)
      FAMILY=android; ANDROID_ABI=arm64-v8a;   TRIPLE=aarch64-linux-android ;;
    androidArm32)
      FAMILY=android; ANDROID_ABI=armeabi-v7a; TRIPLE=armv7a-linux-androideabi ;;
    androidX64)
      FAMILY=android; ANDROID_ABI=x86_64;      TRIPLE=x86_64-linux-android ;;
    androidX86)
      FAMILY=android; ANDROID_ABI=x86;         TRIPLE=i686-linux-android ;;
    *)
      error "Unknown target: $TARGET" ;;
  esac

  # What the target ships: STATIC = Kotlin/Native archive, JNI = JVM library.
  case "$TARGET" in
    ios*)                  HAS_STATIC=1; HAS_JNI=0 ;;
    mingwArm64|android*)   HAS_STATIC=0; HAS_JNI=1 ;;
    *)                     HAS_STATIC=1; HAS_JNI=1 ;;
  esac

  case "$FAMILY" in
    apple)   OPT_FLAGS="$OPT_FLAGS -flto=thin" ;;
    # minSdk < 29 means emulated TLS: its __emutls_* symbols are created during
    # LTO codegen, after the version script applied, so they would leak from
    # the .so as exports. Hidden visibility from the start keeps them local
    # (JNI_OnLoad is JNIEXPORT, i.e. explicitly default).
    android) OPT_FLAGS="$OPT_FLAGS -flto=thin -fvisibility=hidden -fvisibility-inlines-hidden" ;;
    *)       OPT_FLAGS="$OPT_FLAGS -flto" ;;   # ELF/COFF prelink needs one module
  esac

  BUILD_ROOT="$PROJECT_ROOT/build/$TARGET"
  PREFIX="$BUILD_ROOT/prefix"
  OUT_DIR="$PROJECT_ROOT/out/$TARGET"

  case "$FAMILY" in
    apple)   setup_apple_toolchain ;;
    android) setup_android_toolchain ;;
    *)       if [[ -n "$KONAN_TARGET" ]]; then setup_konan_toolchain; else setup_llvm_mingw_toolchain; fi ;;
  esac
  # Where TDLib finds zlib: ours, except on Android (system libz).
  ZLIB_INC="$PREFIX/include"; ZLIB_LIB="$PREFIX/lib/libz.a"
  [[ "$FAMILY" == android ]] && { ZLIB_INC="$SYSROOT/usr/include"; ZLIB_LIB="$SYSROOT/usr/lib/$ANDROID_LIB_TRIPLE/$ANDROID_API/libz.so"; }
  return 0
}

setup_apple_toolchain() {
  [[ "$(uname)" == "Darwin" ]] || error "$TARGET can only be built on macOS"
  SDK_PATH="$(xcrun --sdk "$APPLE_SDK" --show-sdk-path)"
  SDK_VERSION="$(xcrun --sdk "$APPLE_SDK" --show-sdk-version)"
  CC_BIN="$(xcrun --sdk "$APPLE_SDK" -f clang)"
  CXX_BIN="$(xcrun --sdk "$APPLE_SDK" -f clang++)"
  TARGET_CFLAGS="-target $TRIPLE -isysroot $SDK_PATH"
}

# Linux / MinGW: Kotlin/Native's LLVM + the sysroot K/N itself links with.
setup_konan_toolchain() {
  ensure_konan
  ensure_konan_target_deps "$KONAN_TARGET"
  ensure_konan_llvm_dev
  local deps="$KONAN_DATA_DIR/dependencies"
  local toolchain="$deps/$(konan_prop "toolchainDependency.$KONAN_TARGET")"
  case "$FAMILY" in
    linux)
      GCC_TOOLCHAIN="$toolchain"
      SYSROOT="$toolchain/$TRIPLE/sysroot"
      TARGET_CFLAGS="--target=$TRIPLE --sysroot=$SYSROOT --gcc-toolchain=$GCC_TOOLCHAIN -fPIC" ;;
    mingw)
      GCC_TOOLCHAIN=""
      SYSROOT="$toolchain"
      TARGET_CFLAGS="--target=$TRIPLE --sysroot=$SYSROOT" ;;
  esac
  CC_BIN="$LLVM_BIN/clang"
  CXX_BIN="$LLVM_BIN/clang++"
  [[ -d "$SYSROOT" ]] || error "Sysroot not found: $SYSROOT"
}

# Android: the NDK's own clang/sysroot. minSdk 21 = the NDK r28 minimum.
ANDROID_NDK_VERSION="28.2.13676358"   # r28c
ANDROID_API=21
setup_android_toolchain() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  ANDROID_NDK="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$sdk/ndk/$ANDROID_NDK_VERSION}}"
  [[ -f "$ANDROID_NDK/build/cmake/android.toolchain.cmake" ]] \
    || error "Android NDK not found at $ANDROID_NDK (set ANDROID_NDK_ROOT)"
  local host; case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; *) host=linux-x86_64 ;; esac
  LLVM_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/$host/bin"
  SYSROOT="$ANDROID_NDK/toolchains/llvm/prebuilt/$host/sysroot"
  CC_BIN="$LLVM_BIN/clang"; CXX_BIN="$LLVM_BIN/clang++"
  TARGET_CFLAGS="--target=$TRIPLE$ANDROID_API -fPIC"
  # Library dir name in the sysroot (armv7a → arm).
  ANDROID_LIB_TRIPLE="${TRIPLE/armv7a-/arm-}"
}

# mingwArm64: llvm-mingw (clang + MinGW-w64 headers/libs + libc++), pinned.
LLVM_MINGW_VERSION="20261006"
setup_llvm_mingw_toolchain() {
  local flavor
  case "$(uname -s)-$(uname -m)" in
    Darwin-*)      flavor=ucrt-macos-universal ;;
    Linux-x86_64)  flavor=ucrt-ubuntu-22.04-x86_64 ;;
    Linux-aarch64) flavor=ucrt-ubuntu-22.04-aarch64 ;;
    *) error "No llvm-mingw build for $(uname -sm)" ;;
  esac
  local name="llvm-mingw-$LLVM_MINGW_VERSION-$flavor"
  local dir="$PROJECT_ROOT/build/toolchains/$name"
  if [[ ! -x "$dir/bin/clang" ]]; then
    local tarball
    tarball="$(fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$name.tar.xz")"
    mkdir -p "$PROJECT_ROOT/build/toolchains"
    tar -xJf "$tarball" -C "$PROJECT_ROOT/build/toolchains"
  fi
  LLVM_BIN="$dir/bin"
  SYSROOT="$dir/$TRIPLE"
  GCC_TOOLCHAIN=""
  CC_BIN="$LLVM_BIN/clang"; CXX_BIN="$LLVM_BIN/clang++"
  TARGET_CFLAGS="--target=$TRIPLE"
}

# Compiler launcher: ccache when available (CI caches ~/.ccache).
launcher_args() {
  if command -v ccache &>/dev/null; then
    echo "-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
  fi
}

# Run a noisy command with output in a log file; show its tail on failure.
run_logged() {
  local log="$1"; shift
  mkdir -p "$(dirname "$log")"
  if ! "$@" >"$log" 2>&1; then
    tail -40 "$log" >&2
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      # Annotations are readable through the public API without log access.
      local msg; msg="$(tail -25 "$log" | sed -e 's/%/%25/g' -e 's/\r//g' | awk '{printf "%s%%0A", $0}')"
      echo "::error title=${TARGET:-pack.sh}: $(basename "$1")::${msg}"
    fi
    error "Command failed (full log: $log): $*"
  fi
}

# Download a tarball into the shared source cache once.
fetch() {
  local url="$1" file="$SRC_CACHE/$(basename "$1")"
  mkdir -p "$SRC_CACHE"
  if [[ ! -s "$file" ]]; then
    info "Downloading $url" >&2
    curl -fsSL "$url" -o "$file.part" && mv "$file.part" "$file"
  fi
  echo "$file"
}

# Static archiver that understands LLVM bitcode members.
make_archive() {
  local out="$1"; shift
  rm -f "$out"
  case "$FAMILY" in
    apple) xcrun libtool -static -no_warning_for_no_symbols -o "$out" "$@" ;;
    *)     "$LLVM_BIN/llvm-ar" qcs "$out" "$@" ;;
  esac
}
