# shellcheck shell=bash
# Kotlin/Native distribution pinned by kotlin-native.version.
#
# Used for two things, never for building TDLib's Apple slices:
#   * its bundled sysroots/toolchains (glibc 2.19 + libstdc++ 8.3 for Linux,
#     msys2 mingw-w64 for Windows) so our objects match what K/N links against;
#   * the verify step (cinterop + konanc), which is exactly what the consumer
#     project does with the archive.
# No Gradle needed: K/N downloads a target's dependencies into
# ~/.konan/dependencies the first time it links a program for that target.

KONAN_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/kotlin-native.version")"
KONAN_DATA_DIR="${KONAN_DATA_DIR:-$HOME/.konan}"

konan_host() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  echo macos-aarch64 ;;
    Darwin-x86_64) echo macos-x86_64 ;;
    Linux-x86_64)  echo linux-x86_64 ;;
    *) error "Unsupported Kotlin/Native host: $(uname -sm)" ;;
  esac
}

# Sets KONAN_HOME (the unpacked distribution), downloading it when missing.
ensure_konan() {
  local name="kotlin-native-prebuilt-$(konan_host)-$KONAN_VERSION"
  KONAN_HOME="$KONAN_DATA_DIR/$name"
  if [[ ! -x "$KONAN_HOME/bin/konanc" ]]; then
    local tarball
    tarball="$(fetch "https://github.com/JetBrains/kotlin/releases/download/v$KONAN_VERSION/$name.tar.gz")"
    mkdir -p "$KONAN_DATA_DIR"
    tar -xzf "$tarball" -C "$KONAN_DATA_DIR"
  fi
  [[ -x "$KONAN_HOME/bin/konanc" ]] || error "Kotlin/Native not found at $KONAN_HOME"
}

# Gradle-style target name → konanc -target name (macosArm64 → macos_arm64).
konan_target() {
  echo "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]'
}

konan_prop() {
  sed -nE "s/^$1[[:space:]]*=[[:space:]]*//p" "$KONAN_HOME/konan/konan.properties" | head -1
}

konan_host_key() {
  case "$(konan_host)" in
    macos-aarch64) echo macos_arm64 ;;
    macos-x86_64)  echo macos_x64 ;;
    linux-x86_64)  echo linux_x64 ;;
  esac
}

# Make K/N download a target's sysroot/toolchain the way a Gradle build would:
# by linking a trivial program for it once.
ensure_konan_target_deps() {
  local kt="$1" dep
  dep="$(konan_prop "toolchainDependency.$kt")"
  [[ -n "$dep" ]] || error "No toolchainDependency.$kt in konan.properties"
  [[ -d "$KONAN_DATA_DIR/dependencies/$dep" ]] && return 0
  info "Provisioning Kotlin/Native dependencies for $kt" >&2
  local work="$PROJECT_ROOT/build/konan-provision"
  mkdir -p "$work"; echo 'fun main() {}' > "$work/main.kt"
  run_logged "$work/$kt.log" "$KONAN_HOME/bin/konanc" -target "$kt" "$work/main.kt" -o "$work/$kt"
}

# The "dev" LLVM build (adds llvm-objcopy, llvm-nm, opt, ...). K/N already uses
# it as its own LLVM on Linux hosts; on macOS hosts it only ships "essentials",
# so fetch dev from the same JetBrains location K/N would use. Sets LLVM_BIN.
ensure_konan_llvm_dev() {
  local name remote dir
  name="$(konan_prop "llvm.$(konan_host_key).dev")"
  dir="$KONAN_DATA_DIR/dependencies/$name"
  if [[ ! -x "$dir/bin/clang" ]]; then
    remote="$(konan_prop "$name.default" | sed 's/^remote:public://')"
    local tarball
    tarball="$(fetch "$(konan_prop dependenciesUrl)/$remote/$name.tar.gz")"
    tar -xzf "$tarball" -C "$KONAN_DATA_DIR/dependencies"
  fi
  LLVM_BIN="$dir/bin"
}
