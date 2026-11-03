// The tdjson API on this package's own Worker, started on first use
// (new Worker(new URL('./worker.mjs', import.meta.url)), which bundlers such as
// webpack 5 follow). For a Worker of your own, use attach() from client.mjs.
import { attach } from './client.mjs';

export { attach, TdLibClient } from './client.mjs';

let client = null;
const td = () => (client ??= attach(new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module', name: 'tdlib' })));

export function createClientId() { return td().createClientId(); }
export function send(clientId, request) { td().send(clientId, request); }
export function receive(timeout) { return td().receive(timeout); }
export function execute(request) { return td().execute(request); }
export function setLogMessageHandler(maxVerbosityLevel, handler) { td().setLogMessageHandler(maxVerbosityLevel, handler); }
