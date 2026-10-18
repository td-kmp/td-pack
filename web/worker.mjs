// TDLib's Web Worker (started by index.mjs). It owns the Emscripten module and
// runs td_receive whenever TDLib may have something to do: its own timers
// (getTimeout), a request, or an event on one of its WebSockets. Events go to
// the page in batches; the page talks to it with the messages handled below.
import createTdlibModule from './td_wasm.js';

// Messages that arrive while the module loads are handled once it is ready.
const early = [];
let handle = (message) => early.push(message);
self.onmessage = ({ data }) => handle(data);

const fail = (message) => postMessage({ type: 'error', message });

let module;
try {
  module = await createTdlibModule({ onAbort: (what) => fail(`TDLib aborted: ${what}`) });
} catch (e) {
  fail(`TDLib failed to load: ${e?.message ?? e}`);
  throw e;
}

const string = (pointer) => (pointer === 0 ? null : module.UTF8ToString(pointer));
const td = {
  createClientId: module.cwrap('td_emscripten_create_client_id', 'number', []),
  send: module.cwrap('td_emscripten_send', null, ['number', 'string']),
  receive: module.cwrap('td_emscripten_receive', 'number', []),
  execute: module.cwrap('td_emscripten_execute', 'number', ['string']),
  getTimeout: module.cwrap('td_emscripten_get_timeout', 'number', []),
  setLogMessageCallback: module.cwrap('td_set_log_message_callback', null, ['number', 'number']),
};

// The page numbers clients itself (createClientId must be synchronous there).
// TDLib numbers them 1, 2, 3, ... too, so the two only differ if something
// else created a client in this module; then events are renumbered.
const tdIds = new Map();
const pageIds = new Map();
function withPageClientId(event) {
  if (pageIds.size === 0) return event;
  return event.replace(/"@client_id":(\d+)/, (match, id) =>
    pageIds.has(Number(id)) ? `"@client_id":${pageIds.get(Number(id))}` : match);
}

let timer = 0;
let soon = false;

function receive() {
  soon = false;
  clearTimeout(timer);
  const events = [];
  for (let event; (event = string(td.receive())) !== null;) events.push(withPageClientId(event));
  if (events.length > 0) postMessage({ type: 'events', events });
  // TDLib's next timer, in seconds; capped, since setTimeout overflows past ~24 days.
  const timeout = td.getTimeout();
  const seconds = Number.isFinite(timeout) ? Math.min(Math.max(timeout, 0), 60) : 60;
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
        const tdId = td.createClientId();
        if (tdId !== message.clientId) {
          tdIds.set(message.clientId, tdId);
          pageIds.set(tdId, message.clientId);
        }
        break;
      }
      case 'send':
        td.send(tdIds.get(message.clientId) ?? message.clientId, message.request);
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
        fail(`Unknown message: ${message.type}`);
    }
  } catch (e) {
    fail(`${message.type} failed: ${e?.message ?? e}`);
  }
};
early.splice(0).forEach(handle);
receive();
