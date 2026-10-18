// TDLib's JSON interface (td_json_client.h) for the browser. TDLib runs in a
// Web Worker (worker.mjs) that is started on first use, so nothing here waits
// for td_wasm.wasm to load: createClientId and send are synchronous (messages
// reach the Worker in order), receive and execute return promises.
//
// receive(timeout) is td_receive's pull model: the next event of any client
// (with "@client_id", and "@extra" for answers), or null after timeout
// seconds. Like td_receive it allows one receiver at a time.

let worker = null;
let failure = null;
let nextClientId = 1;
let nextExecuteId = 1;
const executions = new Map();
const events = [];
let waiter = null;
let logHandler = null;

function onMessage(message) {
  switch (message.type) {
    case 'events':
      events.push(...message.events);
      if (waiter !== null) waiter.resolve(events.shift());
      break;
    case 'executed':
      executions.get(message.id)?.resolve(message.result);
      executions.delete(message.id);
      break;
    case 'log':
      logHandler?.(message.level, message.message);
      break;
    case 'error':
      fail(new Error(message.message));
      break;
  }
}

// TDLib is gone after a failure: every pending and later call rejects.
function fail(error) {
  failure ??= error;
  executions.forEach(({ reject }) => reject(failure));
  executions.clear();
  waiter?.reject(failure);
}

function post(message) {
  if (failure !== null) throw failure;
  if (worker === null) {
    worker = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module', name: 'tdlib' });
    worker.onmessage = ({ data }) => onMessage(data);
    worker.onerror = (e) => fail(new Error(`TDLib worker failed: ${e.message ?? 'unknown error'}`));
  }
  worker.postMessage(message);
}

export function createClientId() {
  const clientId = nextClientId++;
  post({ type: 'create', clientId });
  return clientId;
}

export function send(clientId, request) {
  post({ type: 'send', clientId, request });
}

export function receive(timeout) {
  if (failure !== null) return Promise.reject(failure);
  if (events.length > 0) return Promise.resolve(events.shift());
  if (waiter !== null) return Promise.reject(new Error('receive() is already waiting: TDLib allows one receiver'));
  return new Promise((resolve, reject) => {
    const done = () => { clearTimeout(timer); waiter = null; };
    const timer = setTimeout(() => { done(); resolve(null); }, Math.max(timeout, 0) * 1000);
    waiter = {
      resolve: (event) => { done(); resolve(event); },
      reject: (error) => { done(); reject(error); },
    };
  });
}

export function execute(request) {
  return new Promise((resolve, reject) => {
    const id = nextExecuteId++;
    executions.set(id, { resolve, reject });
    try {
      post({ type: 'execute', id, request });
    } catch (e) {
      executions.delete(id);
      reject(e);
    }
  });
}

// Messages are logged in the Worker and delivered here afterwards, before the
// answer of the request that logged them. null removes the handler.
export function setLogMessageHandler(maxVerbosityLevel, handler) {
  logHandler = handler;
  post({ type: 'setLogMessageHandler', maxVerbosityLevel, enabled: handler !== null });
}
