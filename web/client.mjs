// The page side of worker.mjs's protocol: td_json_client.h for the browser, with
// receive and execute as promises. attach() binds it to a Worker the caller
// created from worker.mjs (index.mjs does so with this package's own copy).
//
// receive(timeout) is td_receive's pull model: the next event of any client
// (with "@client_id", and "@extra" for answers), or null after timeout seconds;
// one receiver at a time. Once the worker fails — the module did not load,
// TDLib aborted, the version is not the expected one — every pending and later
// call rejects with the same error.

export function attach(worker, expectedVersion = null) {
  return new TdLibClient(worker, expectedVersion);
}

export class TdLibClient {
  #worker;
  #failure = null;
  #nextClientId = 1;
  #nextExecuteId = 1;
  #executions = new Map();
  #events = [];
  #waiter = null;
  #logHandler = null;
  #ready;

  /** Resolves with TDLib's version once the worker has loaded it. */
  ready;

  constructor(worker, expectedVersion) {
    this.#worker = worker;
    this.ready = new Promise((resolve, reject) => { this.#ready = { resolve, reject, expectedVersion }; });
    this.ready.catch(() => {}); // reported through the failing calls, not as an unhandled rejection
    worker.onmessage = ({ data }) => this.#onMessage(data);
    worker.onerror = (e) => this.#fail(new Error(`TDLib worker failed: ${e.message ?? 'unknown error'}`));
  }

  createClientId() {
    const clientId = this.#nextClientId++;
    this.#post({ type: 'create', clientId });
    return clientId;
  }

  send(clientId, request) {
    this.#post({ type: 'send', clientId, request });
  }

  receive(timeout) {
    if (this.#failure !== null) return Promise.reject(this.#failure);
    if (this.#events.length > 0) return Promise.resolve(this.#events.shift());
    if (this.#waiter !== null) return Promise.reject(new Error('receive() is already waiting: TDLib allows one receiver'));
    return new Promise((resolve, reject) => {
      const done = () => { clearTimeout(timer); this.#waiter = null; };
      const timer = setTimeout(() => { done(); resolve(null); }, Math.max(timeout, 0) * 1000);
      this.#waiter = {
        resolve: (event) => { done(); resolve(event); },
        reject: (error) => { done(); reject(error); },
      };
    });
  }

  execute(request) {
    return new Promise((resolve, reject) => {
      const id = this.#nextExecuteId++;
      this.#executions.set(id, { resolve, reject });
      try {
        this.#post({ type: 'execute', id, request });
      } catch (e) {
        this.#executions.delete(id);
        reject(e);
      }
    });
  }

  // Log messages are delivered before the answer of the request that logged
  // them. null removes the handler.
  setLogMessageHandler(maxVerbosityLevel, handler) {
    this.#logHandler = handler;
    this.#post({ type: 'setLogMessageHandler', maxVerbosityLevel, enabled: handler !== null });
  }

  #post(message) {
    if (this.#failure !== null) throw this.#failure;
    this.#worker.postMessage(message);
  }

  #onMessage(message) {
    switch (message.type) {
      case 'ready': {
        const { resolve, expectedVersion } = this.#ready;
        if (expectedVersion !== null && message.version !== expectedVersion) {
          this.#fail(new Error(`the worker runs TDLib ${message.version}, expected ${expectedVersion}`));
        } else {
          resolve(message.version);
        }
        break;
      }
      case 'events':
        this.#events.push(...message.events);
        if (this.#waiter !== null) this.#waiter.resolve(this.#events.shift());
        break;
      case 'executed':
        this.#executions.get(message.id)?.resolve(message.result);
        this.#executions.delete(message.id);
        break;
      case 'log':
        this.#logHandler?.(message.level, message.message);
        break;
      case 'error':
        this.#fail(new Error(message.message));
        break;
    }
  }

  #fail(error) {
    if (this.#failure !== null) return;
    this.#failure = error;
    this.#ready.reject(error);
    this.#executions.forEach(({ reject }) => reject(error));
    this.#executions.clear();
    this.#waiter?.reject(error);
  }
}
