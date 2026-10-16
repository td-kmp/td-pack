#!/usr/bin/env bash
# =============================================================================
# pack.sh — build a size-optimized TDLib static archive for one Kotlin/Native
# target and package it as out/tdlib-<target>.tar.zst.
#
# Usage:
#   ./pack.sh <target> [step...]
#
# Targets (Kotlin/Native names), and what each ships:
#   static (klib) + JNI : macosArm64 macosX64 linuxX64 linuxArm64 mingwX64
#   static (klib)       : iosArm64 iosSimulatorArm64 iosX64
#   JNI                 : mingwArm64 androidArm64 androidArm32
#                         androidX64 androidX86
#
# Steps (default: build test):
#   build = codegen zlib openssl tdlib [prelink package] [jni]
#   test  = [verify] [jni-verify]     (each check runs even if another fails)
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/scripts/pack/common.sh"
for f in konan zlib openssl tdlib prelink package verify jni; do
  source "$PROJECT_ROOT/scripts/pack/$f.sh"
done

[[ $# -ge 1 ]] || { sed -n '3,18p' "$0"; exit 1; }
load_target "$1"; shift

build_steps=(codegen zlib openssl tdlib)
[[ "$HAS_STATIC" == 1 ]] && build_steps+=(prelink package)
[[ "$HAS_JNI" == 1 ]] && build_steps+=(jni)
test_steps=()
[[ "$HAS_STATIC" == 1 ]] && test_steps+=(verify)
[[ "$HAS_JNI" == 1 ]] && test_steps+=(jni-verify)

steps=()
[[ $# -gt 0 ]] || set -- build test
for a in "$@"; do
  case "$a" in
    build) steps+=("${build_steps[@]}") ;;
    test)  steps+=("${test_steps[@]}") ;;
    *)     steps+=("$a") ;;
  esac
done

git -C "$PROJECT_ROOT" submodule update --init --depth=1 td

run_step() {
  case "$1" in
    codegen) codegen ;;
    zlib)    build_zlib ;;
    openssl) build_openssl ;;
    tdlib)   build_tdlib ;;
    prelink) prelink ;;
    package) package ;;
    verify)  verify ;;
    jni)     build_jni ;;
    jni-verify) verify_jni ;;
    *) error "Unknown step: $1" ;;
  esac
}

timings="" failed=()
for step in "${steps[@]}"; do
  step_start=$SECONDS
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::group::$TARGET · $step"
  case "$step" in
    verify|jni-verify)
      # Checks run in a subshell: one failing does not skip the others.
      if ! (run_step "$step"); then
        failed+=("$step")
        [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::warning title=$TARGET $step failed::see the $step group in the log"
      fi ;;
    *) run_step "$step" ;;
  esac
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::endgroup::"
  timings+="$step $((SECONDS - step_start))s, "
done

# Per-step durations as one CI annotation (readable without log access).
[[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::notice title=$TARGET timings::${timings%, }"
[[ ${#failed[@]} -eq 0 ]] || error "Failed checks: ${failed[*]}"
exit 0
