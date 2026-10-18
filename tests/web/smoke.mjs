// Browser counterpart of tests/smoke.c (and, with ?network=1, tests/network.c):
// synchronous execute, the log message callback, IDBFS, then a client
// round-trip driven by receive(), getTimeout() and the wake-up handler.
// Reports one "TDPACK_RESULT ok|fail ..." console line for run.mjs.
import * as td from './tdlib/index.mjs';

const network = new URLSearchParams(location.search).get('network') === '1';

class Failure extends Error {}
const check = (condition, message) => { if (!condition) throw new Failure(message); };

// Polls TDLib like a consumer's event loop: drain receive(), then wait for
// getTimeout() or a wake-up from a socket, whichever comes first.
let wakeUp = null;
td.setWakeUpHandler(() => wakeUp?.());
const nextPoll = () => new Promise((resolve) => {
  const timer = setTimeout(resolve, Math.min(Math.max(td.getTimeout(), 0), 1) * 1000);
  wakeUp = () => { clearTimeout(timer); resolve(); };
});

async function receiveUntil(predicate, seconds) {
  for (const end = Date.now() + seconds * 1000; Date.now() < end;) {
    for (let event; (event = td.receive()) !== null;) {
      if (predicate(event)) return event;
    }
    await nextPoll();
  }
  return null;
}

async function closeClient(client) {
  td.send(client, '{"@type":"close"}');
  await receiveUntil((e) => e.includes('authorizationStateClosed'), 10);
}

async function smoke() {
  td.execute('{"@type":"setLogVerbosityLevel","new_verbosity_level":1}');

  const entities = td.execute('{"@type":"getTextEntities","text":"@telegram /test https://telegram.org"}');
  check(entities?.includes('textEntityTypeUrl'), `getTextEntities failed: ${entities}`);
  check(td.execute('{"@type":"getOption","name":"no_such_option"}') !== null, 'execute returned null');

  const logged = [];
  td.setLogMessageHandler(1, (level, message) => logged.push([level, message]));
  td.execute('{"@type":"addLogMessage","verbosity_level":1,"text":"td-pack log check"}');
  td.setLogMessageHandler(0, null);
  check(logged.some(([level, message]) => level === 1 && message.includes('td-pack log check')),
    `log message handler got ${JSON.stringify(logged)}`);

  td.FS.mkdir('/idb');
  td.FS.mount(td.IDBFS, {}, '/idb');
  td.FS.writeFile('/idb/probe', 'ok');
  await new Promise((resolve, reject) => td.FS.syncfs(false, (e) => (e ? reject(e) : resolve())));

  const client = td.createClientId();
  td.send(client, '{"@type":"getOption","name":"version","@extra":42}');
  const answer = await receiveUntil((e) => e.includes('"@extra":42'), 30);
  check(answer?.includes('optionValueString'), `getOption answer: ${answer}`);
  await closeClient(client);
  return JSON.parse(answer).value;
}

// The full MTProto handshake against the test DC over wss://: the server can
// only answer API_ID_INVALID after it.
async function networkCheck() {
  const client = td.createClientId();
  td.send(client, '{"@type":"getOption","name":"version"}');
  const params = JSON.stringify({
    '@type': 'setTdlibParameters', use_test_dc: true, database_directory: '/idb/network',
    use_message_database: false, use_secret_chats: false, api_id: 1,
    api_hash: '00000000000000000000000000000000', system_language_code: 'en',
    device_model: 'td-pack smoke', application_version: '1.0',
  });
  const answer = await receiveUntil((event) => {
    if (event.includes('authorizationStateWaitTdlibParameters')) td.send(client, params);
    if (event.includes('authorizationStateWaitPhoneNumber')) {
      td.send(client, '{"@type":"setAuthenticationPhoneNumber","phone_number":"+9996620000","@extra":7}');
    }
    return event.includes('"@extra":7');
  }, 150);
  check(answer?.includes('API_ID_INVALID'), `test DC answer: ${answer}`);
  await closeClient(client);
  return JSON.parse(answer).message;
}

try {
  const version = await smoke();
  const handshake = network ? `, test DC: ${await networkCheck()}` : '';
  console.log(`TDPACK_RESULT ok: TDLib ${version}${handshake}`);
} catch (e) {
  console.log(`TDPACK_RESULT fail: ${e instanceof Failure ? e.message : e?.stack ?? e}`);
}
