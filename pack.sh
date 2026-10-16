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
# Steps (default: everything the target ships, in this order):
#   codegen zlib openssl tdlib | prelink package verify | jni jni-verify
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/scripts/pack/common.sh"
for f in konan zlib openssl tdlib prelink package verify jni; do
  source "$PROJECT_ROOT/scripts/pack/$f.sh"
done

[[ $# -ge 1 ]] || { sed -n '3,18p' "$0"; exit 1; }
load_target "$1"; shift

steps=("$@")
if [[ ${#steps[@]} -eq 0 ]]; then
  steps=(codegen zlib openssl tdlib)
  [[ "$HAS_STATIC" == 1 ]] && steps+=(prelink package verify)
  [[ "$HAS_JNI" == 1 ]] && steps+=(jni jni-verify)
fi

git -C "$PROJECT_ROOT" submodule update --init --depth=1 td

for step in "${steps[@]}"; do
  case "$step" in
    codegen) codegen ;;
    zlib)    build_zlib ;;
    openssl) build_openssl ;;
    tdlib)   build_tdlib ;;
    prelink) prelink ;;
    package) package ;;
    verify)  verify ;;
    jni)     build_jni ;;
    jni-verify) verify_jni ;;
    *) error "Unknown step: $step" ;;
  esac
done
