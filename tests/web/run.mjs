// Runs index.html (smoke.mjs) in headless Chrome and relays its console.
// No test framework: a static HTTP server plus the DevTools protocol over
// Node's built-in WebSocket (Node >= 22).
//   usage: node run.mjs <chrome> <dir> <network: 0|1>
// Exits 0 when the page logs "TDPACK_RESULT ok", 1 on "TDPACK_RESULT fail",
// an uncaught exception, or a timeout.
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, normalize } from 'node:path';

const [chromePath, root, network] = process.argv.slice(2);
const timeoutMs = network === '1' ? 180_000 : 90_000;

const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
  try {
    const body = readFileSync(join(root, path === '/' ? 'index.html' : path));
    res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream' }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const pageUrl = `http://127.0.0.1:${server.address().port}/index.html${network === '1' ? '?network=1' : ''}`;

const profile = mkdtempSync(join(tmpdir(), 'tdpack-chrome-'));
const chrome = spawn(chromePath, [
  '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', '--disable-gpu',
  ...(process.env.CI ? ['--no-sandbox'] : []),
  'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

let finished = false;
function finish(code, message) {
  if (finished) return;
  finished = true;
  if (message) console.log(message);
  chrome.kill();
  server.close();
  setTimeout(() => {
    rmSync(profile, { recursive: true, force: true });
    process.exit(code);
  }, 500);
}
setTimeout(() => finish(1, `TDPACK_RESULT fail: timed out after ${timeoutMs / 1000}s`), timeoutMs);
chrome.on('exit', (code) => finish(1, `TDPACK_RESULT fail: Chrome exited (${code})`));

// "DevTools listening on ws://127.0.0.1:<port>/devtools/browser/<id>"
const port = await new Promise((resolve) => {
  let stderr = '';
  chrome.stderr.on('data', (chunk) => {
    stderr += chunk;
    const match = stderr.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
    if (match) resolve(match[1]);
  });
});

const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
let nextId = 1;
const call = (method, params = {}) => ws.send(JSON.stringify({ id: nextId++, method, params }));

ws.onmessage = ({ data }) => {
  const { method, params } = JSON.parse(data);
  if (method === 'Runtime.consoleAPICalled') {
    const text = params.args.map((a) => a.value ?? a.description ?? '').join(' ');
    console.log(text);
    if (text.startsWith('TDPACK_RESULT ok')) finish(0);
    else if (text.startsWith('TDPACK_RESULT')) finish(1);
  } else if (method === 'Runtime.exceptionThrown') {
    const d = params.exceptionDetails;
    finish(1, `TDPACK_RESULT fail: uncaught ${d.exception?.description ?? d.text}`);
  }
};
ws.onopen = () => {
  call('Runtime.enable');
  call('Page.navigate', { url: pageUrl });
};
