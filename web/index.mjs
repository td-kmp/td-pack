// td_json_client.h for the thread that imports this: strings instead of the C pointers of the raw exports.
import init, {
  _td_emscripten_create_client_id,
  _td_emscripten_send,
  _td_emscripten_receive,
  _td_emscripten_execute,
  _td_emscripten_get_timeout,
  _td_set_log_message_callback,
  _free,
  addFunction,
  removeFunction,
  stringToNewUTF8,
  UTF8ToString,
} from './td_wasm.js';

export { FS, IDBFS, WORKERFS } from './td_wasm.js';

const websocket = {};
const string = (pointer) => (pointer === 0 ? null : UTF8ToString(pointer));

function withString(value, block) {
  const pointer = stringToNewUTF8(value);
  try {
    return block(pointer);
  } finally {
    _free(pointer);
  }
}

export default function initTdlib(options = {}) {
  return init({ ...options, websocket });
}

export const createClientId = () => _td_emscripten_create_client_id();
export const send = (clientId, request) => withString(request, (pointer) => _td_emscripten_send(clientId, pointer));
export const receive = () => string(_td_emscripten_receive());
export const execute = (request) => withString(request, (pointer) => string(_td_emscripten_execute(pointer)));
export const getTimeout = () => _td_emscripten_get_timeout();
export const onSocketEvent = (event, callback) => websocket.on(event, callback);

let logCallback = 0;

export function setLogMessageHandler(maxVerbosityLevel, handler) {
  const previous = logCallback;
  logCallback = handler === null ? 0 : addFunction((level, text) => handler(level, UTF8ToString(text)), 'vii');
  _td_set_log_message_callback(handler === null ? 0 : maxVerbosityLevel, logCallback);
  if (previous !== 0) removeFunction(previous);
}
