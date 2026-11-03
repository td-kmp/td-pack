# td-pack

Size-optimized prebuilt [TDLib](https://github.com/tdlib/td) native libraries for Kotlin
Multiplatform, published as GitHub Release assets. This repo builds only the natives; the
KMP library is assembled (cinterop, packaging, Maven publication) by a separate Gradle
project that downloads these archives — the same split as JetBrains' skia-pack / skiko.

`td` is a git submodule that `update.yml` moves to TDLib's latest master every week.

## Artifacts

Targets use Kotlin/Native names. `tdlib.properties` in every archive records the TDLib
version/commit and how to consume it.

### Kotlin/Native — `tdlib-<target>.tar.zst`

| Targets |
|---|
| `macosArm64` `macosX64` `iosArm64` `iosSimulatorArm64` `iosX64` `linuxX64` `linuxArm64` `mingwX64` |

```
lib/libtdjson.a                       TDLib + OpenSSL + zlib, one prelinked object
include/td/telegram/td_json_client.h
include/td/telegram/td_log.h
include/td/telegram/tdjson_export.h   always static (TDJSON_STATIC_DEFINE baked in)
tdlib.properties                      headers, staticLibraries, linkerOpts
```

The cinterop `.def` needs `headers`, `staticLibraries = libtdjson.a` and the `linkerOpts`
from `tdlib.properties` (empty except on `mingwX64`). Keep `libraryPaths` out of the
`.def` itself (pass `-libraryPath`): cinterop records it in the published klib.

### JNI — `tdlib-jni-<platform>.tar.zst`

Named the way the JVM sees the platform (like skiko's runtime jars); Android by ABI, i.e.
the `jniLibs/<abi>` directory of `androidTarget()`:

| Platforms | Built as `pack.sh` target |
|---|---|
| `macos-arm64` `macos-x64` | `macosArm64` `macosX64` |
| `linux-x64` `linux-arm64` | `linuxX64` `linuxArm64` |
| `windows-x64` `windows-arm64` | `mingwX64` `mingwArm64` |
| `android-arm64-v8a` `android-armeabi-v7a` `android-x86_64` `android-x86` | `androidArm64` `androidArm32` `androidX64` `androidX86` |

Windows libraries are built with MinGW-w64 toolchains (cross-compiled on Linux/macOS). That
is fine for any Windows JVM: JNI is a plain C ABI, and the DLL carries its C++ runtime, so it
only imports system DLLs (verified against Temurin under wine).

`lib/libtdjsonjava.so` / `lib/libtdjsonjava.dylib` / `lib/tdjsonjava.dll` — natives for
`io.xbot.tdlib.NativeBridge` (see `scripts/pack/jni.sh` and `tests/jni`):

```kotlin
package io.xbot.tdlib

object NativeBridge {
    fun interface LogMessageHandler { fun onLogMessage(verbosityLevel: Int, message: String) }

    @JvmStatic external fun nativeCreateClientId(): Int
    @JvmStatic external fun nativeSend(clientId: Int, request: String)
    @JvmStatic external fun nativeReceive(timeout: Double): String?
    @JvmStatic external fun nativeExecute(request: String): String?
    @JvmStatic external fun nativeSetLogMessageHandler(maxVerbosityLevel: Int, handler: LogMessageHandler?)
}
```

Only `JNI_OnLoad` is exported and the C++ runtime is linked in, so the library depends on
OS libraries only. Android: minSdk 21, 16 KB page aligned, system `libz`.

Close every client (wait for `authorizationStateClosed`) before the process exits:
otherwise `atexit` tears OpenSSL down under TDLib's still-running threads.

### Web — `tdlib-web.tar.zst`, `tdlib-web.tgz`

One WebAssembly module for Kotlin/JS and Kotlin/Wasm (`pack.sh` target `web`), as an npm
package `@td-kmp/tdlib-wasm`. `tdlib-web.tgz` is the same package in `npm pack` format: npm and
yarn install it from its release URL, so no registry is involved:
`"@td-kmp/tdlib-wasm": "https://github.com/td-kmp/td-pack/releases/download/v<version>/tdlib-web.tgz"`.

```
td_wasm.js, td_wasm.wasm   Emscripten output (MODULARIZE=instance, web + worker), single-threaded
index.mjs, index.d.ts      top-level functions over the raw exports, with strings
package.json, tdlib.properties
```

The module runs on whichever thread imports it; the package has no Web Worker. Applications write
their own (tdlib-kmp's `WorkerTdLib` documents the protocol and has a sample):

```js
import initTdlib, { createClientId, send, receive, execute, getTimeout, onSocketEvent, FS, IDBFS } from '@td-kmp/tdlib-wasm';

await initTdlib();
const id = createClientId();
send(id, request);
receive();                 // string | null, never blocks
```

All TDLib's work happens inside `receive`: `send` only queues, so call it after requests, on
`onSocketEvent` and on `getTimeout`, and at least every second, since that timeout does not cover
work TDLib queues for itself. No `SharedArrayBuffer`, so no COOP/COEP headers. TDLib connects to
Telegram over `wss://` (`*.web.telegram.org/apiws`); `addProxy` is unsupported.

## How the archives get small

* Everything (TDLib, OpenSSL, zlib) is compiled to LLVM bitcode with `-Os`.
* **Prelink** runs whole-program LTO with only the tdjson C API exported
  (`td/tdclientjson_export_list`): all other symbols are internalized and dead code is
  deleted before shipping. Apple: `ld64 -r -exported_symbols_list`. ELF/COFF: lld LTO as a
  shared library with `--lto-emit-llvm`, COMDATs of internal symbols dropped, compiled to
  one object (ELF re-attaches OpenSSL's asm with `ld.lld -r`; MinGW OpenSSL is `no-asm`).
* OpenSSL 3.5 (LTS) is configured with everything TDLib does not use disabled.
* A klib can only carry static archives — Kotlin/Native's linker keeps `*.a`/`*.lib` from a
  klib's `included/` directory and silently drops `.so`/`.dylib` — so the result stays a
  plain `.a`, just with one object in it.
* JNI libraries are one LTO link of the same bitcode with only `JNI_OnLoad` exported,
  `--gc-sections`, `--icf=all`, stripped.

## Toolchains

| Targets | Host | Toolchain |
|---|---|---|
| Apple | macOS | Xcode; min macOS 12 / iOS 15 (Kotlin/Native's minimums) |
| `linuxX64` `linuxArm64` `mingwX64` | macOS or Linux | Kotlin/Native's LLVM + its sysroots: glibc 2.19 / 2.25 + libstdc++ 8.3, msys2 mingw-w64 |
| `mingwArm64` (JNI only, no K/N target) | macOS or Linux | [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (pinned) |
| Android | macOS or Linux | NDK r28c |
| `web` | macOS or Linux | Emscripten SDK (pinned, installed into `build/toolchains/emsdk`); zlib from its port |

The Kotlin/Native version is pinned in `kotlin-native.version`. Its distribution and target
sysroots are downloaded on demand into `~/.konan` — no Gradle needed.

## Building locally

```bash
./pack.sh <target> [step...]
# steps: codegen zlib openssl tdlib | prelink package verify | jni jni-verify
#        | web-link web-package web-verify
```

Requirements: CMake, Ninja, perl, zstd, a JDK with headers (`JAVA_HOME`); ccache is used
when present. `web` also needs Python ≥ 3.10 for the Emscripten SDK (`EMSDK_PYTHON=<python3>` when
the default one is older, as on macOS), Node.js ≥ 22 (npm, tests) and Chrome or Chromium (`CHROME`).
Android needs the NDK (`ANDROID_NDK_ROOT`, or r28c in the Android SDK).

Outputs go to `out/` (archives) and `build/<target>/` (work trees, logs).

### Verification

`verify` links `tests/smoke.c` and a cinterop + `konanc` program against the archive;
`jni-verify` checks the JNI library's exports/dependencies (and Android's 16 KB alignment)
and runs `tests/jni`. They run where the host can:

* natively (macOS, Linux);
* a booted iOS simulator: `TDPACK_SIM_DEVICE=<udid>`;
* Docker: Linux in the oldest distro matching the sysroot's glibc, MinGW under wine
  (`tests/docker/wine.Dockerfile`), JNI in `eclipse-temurin`;
* an Android device/emulator via `dalvikvm`: `TDPACK_ANDROID_SERIAL=<adb serial>`;
* `web-verify`: `tests/web/smoke.mjs` in headless Chrome, loading the package over HTTP as
  a bundle would (execute, log handler, storage, client round-trips).

`TDPACK_NETWORK_TEST=1` adds `tests/network.c`: a full MTProto handshake with Telegram's
test DC (an invalid `api_id` answered with `API_ID_INVALID`), which proves the trimmed
OpenSSL still has everything TDLib needs; for `web`, the same handshake from the browser
over `wss://`.

## License

TDLib is licensed under the Boost Software License. See
[LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt).
