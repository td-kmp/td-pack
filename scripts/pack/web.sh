# shellcheck shell=bash
# Web: TDLib as one Emscripten module, shipped as an npm package in
# out/tdlib-web.tar.zst:
#   package.json
#   index.mjs, index.d.ts   the tdjson API (td_json_client.h) for the page;
#                           receive and execute return promises (web/index.mjs)
#   worker.mjs              the Web Worker TDLib runs in, started on first use
#   td_wasm.js, td_wasm.wasm  Emscripten output (an EXPORT_ES6 factory)
#   tdlib.properties
# and the same package as out/tdlib-web.tgz (npm pack format): npm and yarn
# install it straight from its release URL, so no npm registry is needed.
#
# Inside the Worker the API is td_emscripten.cpp's: TDLib has no threads, so
# td_receive never blocks and getTimeout() says when to poll again. td's own td_wasm
# target is not used: its flags and --post-js target the Emscripten 3.1.1
# runtime, so web_link links the same objects with settings of its own.

web_link() {
  banner "Link — $TARGET"
  local work="$BUILD_ROOT/web"
  rm -rf "$work" "$OUT_DIR"; mkdir -p "$work" "$OUT_DIR"

  local archives=()
  while IFS= read -r a; do archives+=("$a"); done < <(td_archives)
  archives+=("$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a")
  info "Inputs: ${#archives[@]} archives"

  local settings=(
    -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createTdlibModule
    -sENVIRONMENT=web,worker
    -sUSE_ZLIB=1
    -sALLOW_MEMORY_GROWTH=1
    # Emscripten's default before 3.1.27; td's web build was made for it.
    -sSTACK_SIZE=5MB
    # td connects to "host/path" addresses; the socket layer turns this into
    # wss://host:port/path.
    "-sWEBSOCKET_URL=wss:#"
    # addFunction, for the log message callback.
    -sALLOW_TABLE_GROWTH=1
    -sEXPORTED_FUNCTIONS=_main,_td_set_log_message_callback
    -sEXPORTED_RUNTIME_METHODS=FS,IDBFS,cwrap,addFunction,removeFunction,UTF8ToString
    -lidbfs.js
  )
  # shellcheck disable=SC2086
  run_progress "$work/link.log" "emcc link (LTO)" time "$CXX_BIN" $OPT_FLAGS "${settings[@]}" \
    "$BUILD_ROOT/td/CMakeFiles/td_wasm.dir/td/telegram/td_emscripten.cpp.o" "${archives[@]}" \
    -o "$OUT_DIR/td_wasm.js"
  success "td_wasm.wasm: $(du -h "$OUT_DIR/td_wasm.wasm" | cut -f1), td_wasm.js: $(du -h "$OUT_DIR/td_wasm.js" | cut -f1)"
}

web_package() {
  banner "Package — $TARGET"
  local version; version="$(td_version)"
  cp "$PROJECT_ROOT/web/index.mjs" "$PROJECT_ROOT/web/index.d.ts" "$PROJECT_ROOT/web/worker.mjs" "$OUT_DIR/"
  sed "s/@VERSION@/$version/" "$PROJECT_ROOT/web/package.json" > "$OUT_DIR/package.json"

  cat > "$OUT_DIR/tdlib.properties" <<EOF
target=$TARGET
tdlib.version=$version
tdlib.commit=$(git -C "$TD_DIR" rev-parse HEAD)
openssl.version=$OPENSSL_VERSION
emscripten.version=$EMSDK_VERSION
EOF

  local archive="$PROJECT_ROOT/out/tdlib-$TARGET.tar.zst"
  tar -C "$OUT_DIR" -cf - . | zstd -19 -T0 -q -f -o "$archive"
  local tgz; tgz="$(cd "$OUT_DIR" && npm pack --silent --pack-destination "$BUILD_ROOT")"
  mv "$BUILD_ROOT/$tgz" "$PROJECT_ROOT/out/tdlib-$TARGET.tgz"
  # What a browser downloads: the .wasm as a server would send it.
  local gz; gz="$(gzip -9c "$OUT_DIR/td_wasm.wasm" | wc -c | awk '{printf "%.1fM", $1 / 1048576}')"
  success "$(basename "$archive"): $(du -h "$archive" | cut -f1), tdlib-$TARGET.tgz: $(du -h "$PROJECT_ROOT/out/tdlib-$TARGET.tgz" | cut -f1) (td_wasm.wasm gzipped: $gz)"
}

# Chrome / Chromium for the headless run.
find_chrome() {
  local c
  for c in "${CHROME:-}" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "$(command -v google-chrome 2>/dev/null || true)" "$(command -v chromium 2>/dev/null || true)" \
           "$(command -v chromium-browser 2>/dev/null || true)"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Runs tests/web/smoke.mjs against the packaged module in headless Chrome,
# the way a consumer's bundle loads it: as an ES module over HTTP.
# With TDPACK_NETWORK_TEST=1 it also does the test DC handshake over wss://.
web_verify() {
  banner "Verify — $TARGET"
  local work="$BUILD_ROOT/verify"
  rm -rf "$work"; mkdir -p "$work/tdlib"
  cp -R "$OUT_DIR/." "$work/tdlib/"
  cp "$PROJECT_ROOT/tests/web/index.html" "$PROJECT_ROOT/tests/web/smoke.mjs" "$work/"

  local chrome; chrome="$(find_chrome)" || error "Chrome not found (set CHROME)"
  run_progress "$work/chrome.log" "browser smoke test" time \
    node "$PROJECT_ROOT/tests/web/run.mjs" "$chrome" "$work" "${TDPACK_NETWORK_TEST:-0}"
  success "Browser smoke test: $(grep -o 'TDPACK_RESULT.*' "$work/chrome.log" | cut -c1-120)"
}
