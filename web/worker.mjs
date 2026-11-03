// TDLib's Web Worker. It owns the Emscripten module and runs td_receive whenever
// TDLib may have work: on its own timers (getTimeout), after a request, on a
// WebSocket event. Events go to the page in batches. The page side of this
// protocol is client.mjs:
//   page → worker  create {clientId} | send {clientId, request} | execute {id, request}
//                  | setLogMessageHandler {maxVerbosityLevel, enabled}
//   worker → page  ready {version} | events {events: string[]} | executed {id, result}
//                  | log {level, message} | error {message}
// Storage: /tdlib is an IDBFS mount (IndexedDB database "/tdlib"), loaded before
// the first message is handled and written back every SYNC_INTERVAL_MS and when
// a client closes. Everything else lives in memory.
import createTdlibModule from './td_wasm.js';

const PERSISTENT_ROOT = '/tdlib';
const SYNC_INTERVAL_MS = 5000;

// Messages that arrive while the module loads are handled once it is ready.
const early = [];
let handle = (message) => early.push(message);
self.onmessage = ({ data }) => handle(data);

const fail = (message) => postMessage({ type: 'error', message });

let module;
try {
  module = await createTdlibModule({ onAbort: (what) => fail(`TDLib aborted: ${what}`) });
  module.FS.mkdir(PERSISTENT_ROOT);
  module.FS.mount(module.IDBFS, {}, PERSISTENT_ROOT);
  await syncfs(true);
} catch (e) {
  fail(`TDLib failed to load: ${e?.message ?? e}`);
  throw e;
}

function syncfs(populate) {
  return new Promise((resolve, reject) => module.FS.syncfs(populate, (err) => (err ? reject(err) : resolve())));
}

let persisting = false;
async function persist() {
  if (persisting) return;
  persisting = true;
  try {
    await syncfs(false);
  } catch (e) {
    postMessage({ type: 'log', level: 1, message: `IDBFS sync failed: ${e?.message ?? e}` });
  } finally {
    persisting = false;
  }
}
setInterval(persist, SYNC_INTERVAL_MS);

const string = (pointer) => (pointer === 0 ? null : module.UTF8ToString(pointer));
const td = {
  createClientId: module.cwrap('td_emscripten_create_client_id', 'number', []),
  send: module.cwrap('td_emscripten_send', null, ['number', 'string']),
  receive: module.cwrap('td_emscripten_receive', 'number', []),
  execute: module.cwrap('td_emscripten_execute', 'number', ['string']),
  getTimeout: module.cwrap('td_emscripten_get_timeout', 'number', []),
  setLogMessageCallback: module.cwrap('td_set_log_message_callback', null, ['number', 'number']),
};

let timer = 0;
let soon = false;

function receive() {
  soon = false;
  clearTimeout(timer);
  const events = [];
  for (let event; (event = string(td.receive())) !== null;) events.push(event);
  if (events.length > 0) postMessage({ type: 'events', events });
  // A closed client has written its database: flush now, not at the next interval.
  if (events.some((event) => event.includes('"authorizationStateClosed"'))) persist();
  // getTimeout is a hint: work TDLib queues for itself (the steps of closing an
  // instance, say) does not show in it. Poll again at once after events, and at
  // least every second.
  const timeout = td.getTimeout();
  const seconds = events.length > 0 ? 0 : Number.isFinite(timeout) ? Math.min(Math.max(timeout, 0), 1) : 1;
  timer = setTimeout(receive, seconds * 1000);
}

function receiveSoon() {
  if (soon) return;
  soon = true;
  clearTimeout(timer);
  timer = setTimeout(receive, 0);
}

// TDLib's sockets are WebSockets: their events only queue data for td_receive.
for (const event of ['open', 'message', 'close', 'error']) module.websocket.on(event, receiveSoon);

let logCallback = 0;

handle = (message) => {
  try {
    switch (message.type) {
      case 'create': {
        // The page numbers clients itself (createClientId is synchronous there),
        // from 1 in creation order, as TDLib does; nothing else creates clients here.
        const id = td.createClientId();
        if (id !== message.clientId) fail(`client id mismatch: page ${message.clientId}, TDLib ${id}`);
        break;
      }
      case 'send':
        td.send(message.clientId, message.request);
        receiveSoon();
        break;
      case 'execute':
        postMessage({ type: 'executed', id: message.id, result: string(td.execute(message.request)) });
        break;
      case 'setLogMessageHandler': {
        const previous = logCallback;
        logCallback = message.enabled
          ? module.addFunction((level, text) => postMessage({ type: 'log', level, message: module.UTF8ToString(text) }), 'vii')
          : 0;
        td.setLogMessageCallback(message.enabled ? message.maxVerbosityLevel : 0, logCallback);
        if (previous !== 0) module.removeFunction(previous);
        break;
      }
      default:
        fail(`unknown message: ${message.type}`);
    }
  } catch (e) {
    fail(`${message.type} failed: ${e?.message ?? e}`);
  }
};

postMessage({ type: 'ready', version: JSON.parse(string(td.execute('{"@type":"getOption","name":"version"}'))).value });
early.splice(0).forEach(handle);
receive();
