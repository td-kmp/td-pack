// Browser counterpart of tests/smoke.c (and, with ?network=1, tests/network.c),
// against the package's page API: TDLib runs in its Worker, execute and receive
// are promises, createClientId and send are synchronous.
// Reports one "TDPACK_RESULT ok|fail ..." console line for run.mjs.
import * as td from './tdlib/index.mjs';

const network = new URLSearchParams(location.search).get('network') === '1';

class Failure extends Error {}
const check = (condition, message) => { if (!condition) throw new Failure(message); };

// One receiver, like td_receive: the next event of any client until the predicate matches.
async function receiveUntil(predicate, seconds) {
  for (const end = Date.now() + seconds * 1000; Date.now() < end;) {
    const event = await td.receive(1.0);
    if (event !== null && predicate(event)) return event;
  }
  return null;
}

async function closeClient(client) {
  td.send(client, '{"@type":"close"}');
  await receiveUntil((e) => e.includes('authorizationStateClosed') && e.includes(`"@client_id":${client}`), 10);
}

async function smoke() {
  await td.execute('{"@type":"setLogVerbosityLevel","new_verbosity_level":1}');

  const entities = await td.execute('{"@type":"getTextEntities","text":"@telegram /test https://telegram.org"}');
  check(entities?.includes('textEntityTypeUrl'), `getTextEntities failed: ${entities}`);

  // Log messages arrive from the Worker before the answer of the request that logged them.
  const logged = [];
  td.setLogMessageHandler(1, (level, message) => logged.push([level, message]));
  await td.execute('{"@type":"addLogMessage","verbosity_level":1,"text":"td-pack log check"}');
  td.setLogMessageHandler(0, null);
  check(logged.some(([level, message]) => level === 1 && message.includes('td-pack log check')),
    `log message handler got ${JSON.stringify(logged)}`);

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
  console.log(`TDPACK_RESULT ok: TDLib ${version} (in a Worker)${handshake}`);
} catch (e) {
  console.log(`TDPACK_RESULT fail: ${e instanceof Failure ? e.message : e?.stack ?? e}`);
}
