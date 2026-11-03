// Browser counterpart of tests/smoke.c (and, with ?network=1, tests/network.c): the module on the page's
// thread, polled the way td_emscripten.cpp expects. Reports one "TDPACK_RESULT ok|fail ..." line for run.mjs.
import initTdlib, * as td from './tdlib/index.mjs';

const network = new URLSearchParams(location.search).get('network') === '1';

class Failure extends Error {}
const check = (condition, message) => { if (!condition) throw new Failure(message); };

await initTdlib();

async function receiveUntil(predicate, seconds) {
  for (const end = Date.now() + seconds * 1000; Date.now() < end;) {
    const event = td.receive();
    if (event) {
      if (predicate(event)) return event;
    } else {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }
  return null;
}

async function closeClient(client) {
  td.send(client, '{"@type":"close"}');
  const closed = await receiveUntil((e) => e.includes('authorizationStateClosed') && e.includes(`"@client_id":${client}`), 10);
  check(closed !== null, `client ${client} did not close`);
}

async function smoke() {
  td.execute('{"@type":"setLogVerbosityLevel","new_verbosity_level":1}');
  const entities = td.execute('{"@type":"getTextEntities","text":"@telegram /test https://telegram.org"}');
  check(entities?.includes('textEntityTypeUrl'), `getTextEntities failed: ${entities}`);

  const logged = [];
  td.setLogMessageHandler(1, (level, message) => logged.push(message));
  td.execute('{"@type":"addLogMessage","verbosity_level":1,"text":"td-pack log check"}');
  td.setLogMessageHandler(0, null);
  check(logged.some((message) => message.includes('td-pack log check')), `log handler got ${JSON.stringify(logged)}`);

  // Everything tdlib-kmp's sample worker uses for storage.
  td.FS.mkdir('/idb');
  td.FS.mount(td.IDBFS, {}, '/idb');
  await new Promise((resolve, reject) => td.FS.syncfs(true, (e) => (e ? reject(e) : resolve())));
  check(td.WORKERFS !== undefined, 'WORKERFS is not exported');

  const first = td.createClientId();
  const second = td.createClientId();
  check(first !== second, `client ids: ${first}, ${second}`);
  td.send(second, '{"@type":"getOption","name":"version","@extra":42}');
  const answer = await receiveUntil((e) => e.includes('"@extra":42'), 30);
  check(answer?.includes('optionValueString') && answer.includes(`"@client_id":${second}`), `getOption answer: ${answer}`);
  await closeClient(second);
  return JSON.parse(answer).value;
}

// The full MTProto handshake against the test DC over wss://: the server can
// only answer API_ID_INVALID after it.
async function networkCheck() {
  const client = td.createClientId();
  td.send(client, '{"@type":"getOption","name":"version"}');
  const params = JSON.stringify({
    '@type': 'setTdlibParameters', use_test_dc: true, database_directory: '/tdlib-network',
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
