# CMake toolchain for Linux / MinGW targets built against Kotlin/Native's own
# sysroots, so the objects match what K/N links them with:
#   linux: clang + gcc 8.3 toolchain (libstdc++ 8.3, glibc 2.19 / 2.25)
#   mingw: clang + msys2 mingw-w64 (GCC 9.2 libstdc++, winpthreads)
#
# Configured from scripts/pack/common.sh through cache variables:
#   TDPACK_LLVM_BIN       K/N LLVM bin dir (clang, ld.lld, llvm-ar)
#   TDPACK_TRIPLE         clang target triple
#   TDPACK_SYSROOT        sysroot
#   TDPACK_GCC_TOOLCHAIN  gcc toolchain root (linux only)
#   TDPACK_SYSTEM         Linux | Windows
#   TDPACK_PROCESSOR      x86_64 | aarch64
#   TDPACK_PREFIX         where our zlib/OpenSSL are installed

set(CMAKE_SYSTEM_NAME "${TDPACK_SYSTEM}")
set(CMAKE_SYSTEM_PROCESSOR "${TDPACK_PROCESSOR}")

set(CMAKE_C_COMPILER "${TDPACK_LLVM_BIN}/clang")
set(CMAKE_CXX_COMPILER "${TDPACK_LLVM_BIN}/clang++")
set(CMAKE_C_COMPILER_TARGET "${TDPACK_TRIPLE}")
set(CMAKE_CXX_COMPILER_TARGET "${TDPACK_TRIPLE}")
set(CMAKE_SYSROOT "${TDPACK_SYSROOT}")

# llvm-ar writes an LTO-aware symbol index itself; no separate ranlib needed.
set(CMAKE_AR "${TDPACK_LLVM_BIN}/llvm-ar" CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "" CACHE FILEPATH "" FORCE)
foreach(lang C CXX)
  set(CMAKE_${lang}_ARCHIVE_CREATE "<CMAKE_AR> qcs <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_APPEND "<CMAKE_AR> qs <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_FINISH "")
endforeach()

# CMAKE_<LANG>_COMPILER_TARGET / CMAKE_SYSROOT are not passed on every link line
# (try_compile checks, notably on macOS hosts), so carry both in the flags too.
set(_tdpack_flags " --target=${TDPACK_TRIPLE} --sysroot=${TDPACK_SYSROOT}")
if (TDPACK_GCC_TOOLCHAIN)
  string(APPEND _tdpack_flags " --gcc-toolchain=${TDPACK_GCC_TOOLCHAIN}")
endif()
set(CMAKE_C_FLAGS_INIT "${_tdpack_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_tdpack_flags}")
# Only used for CMake's own try_compile checks; the shipped archive is never
# linked here.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld${_tdpack_flags}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld${_tdpack_flags}")

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CMAKE_FIND_ROOT_PATH "${TDPACK_SYSROOT}" "${TDPACK_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
