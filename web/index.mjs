// TDLib's JSON interface for the browser. Importing this module downloads and
// instantiates td_wasm.wasm (top-level await), so everything below is
// synchronous; import './td_wasm.js' instead to instantiate it yourself.
//
// TDLib has no threads here: receive() never blocks. Call it again after
// send(), after getTimeout() seconds, and when the wake-up handler fires.
import createTdlibModule from './td_wasm.js';

export const module = await createTdlibModule();

const string = (pointer) => (pointer === 0 ? null : module.UTF8ToString(pointer));

const createClientIdImpl = module.cwrap('td_emscripten_create_client_id', 'number', []);
const sendImpl = module.cwrap('td_emscripten_send', null, ['number', 'string']);
const receiveImpl = module.cwrap('td_emscripten_receive', 'number', []);
const executeImpl = module.cwrap('td_emscripten_execute', 'number', ['string']);
const getTimeoutImpl = module.cwrap('td_emscripten_get_timeout', 'number', []);
const setLogMessageCallback = module.cwrap('td_set_log_message_callback', null, ['number', 'number']);

export const createClientId = () => createClientIdImpl();
export const send = (clientId, request) => sendImpl(clientId, request);
export const receive = () => string(receiveImpl());
export const execute = (request) => string(executeImpl(request));
export const getTimeout = () => getTimeoutImpl();

let logCallback = 0;

// The handler runs synchronously inside TDLib; null removes it.
export function setLogMessageHandler(maxVerbosityLevel, handler) {
  const previous = logCallback;
  logCallback = handler === null
    ? 0
    : module.addFunction((level, message) => handler(level, module.UTF8ToString(message)), 'vii');
  setLogMessageCallback(handler === null ? 0 : maxVerbosityLevel, logCallback);
  if (previous !== 0) module.removeFunction(previous);
}

// TDLib's sockets are WebSockets: when one opens, closes or gets data,
// receive() is due now, not after getTimeout().
let wakeUpHandler = null;
for (const event of ['open', 'message', 'close', 'error']) {
  module.websocket.on(event, () => wakeUpHandler?.());
}

// The handler only signals; call receive() from the event loop, not inside it. null removes it.
export function setWakeUpHandler(handler) {
  wakeUpHandler = handler;
}

// Emscripten's file system. TDLib's files live in memory (MEMFS) unless a
// directory is mounted with IDBFS and synced with FS.syncfs.
export const FS = module.FS;
export const IDBFS = module.IDBFS;
