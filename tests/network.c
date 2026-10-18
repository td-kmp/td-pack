// Network smoke test: proves the trimmed OpenSSL still carries everything
// MTProto needs (RSA, DH over BN, AES-IGE, SHA). It connects to Telegram's
// *test* DC with a deliberately invalid api_id; the server can only answer
// API_ID_INVALID after a complete auth-key handshake.
//   usage: network <empty-database-dir>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <td/telegram/td_json_client.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <database-dir>\n", argv[0]);
    return 64;
  }
  td_execute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}");
  int client = td_create_client_id();
  td_send(client, "{\"@type\":\"getOption\",\"name\":\"version\"}");

  char params[2048];
  snprintf(params, sizeof params,
           "{\"@type\":\"setTdlibParameters\",\"use_test_dc\":true,\"database_directory\":\"%s\","
           "\"use_message_database\":false,\"use_secret_chats\":false,\"api_id\":1,"
           "\"api_hash\":\"00000000000000000000000000000000\",\"system_language_code\":\"en\","
           "\"device_model\":\"td-pack smoke\",\"application_version\":\"1.0\"}",
           argv[1]);

  // Must not return while TDLib threads are still running: atexit() tears
  // down OpenSSL and a late RAND_bytes() in a TDLib thread then aborts.
  for (time_t end = time(NULL) + 90; time(NULL) < end;) {
    const char *event = td_receive(1.0);
    if (event == NULL) {
      continue;
    }
    if (strstr(event, "authorizationStateWaitTdlibParameters") != NULL) {
      td_send(client, params);
    } else if (strstr(event, "authorizationStateWaitPhoneNumber") != NULL) {
      td_send(client,
              "{\"@type\":\"setAuthenticationPhoneNumber\",\"phone_number\":\"+9996620000\",\"@extra\":7}");
    } else if (strstr(event, "\"@extra\":7") != NULL) {
      puts(event);
      int ok = strstr(event, "API_ID_INVALID") != NULL;
      td_send(client, "{\"@type\":\"close\"}");
      for (time_t stop = time(NULL) + 10; time(NULL) < stop;) {
        const char *e = td_receive(1.0);
        if (e != NULL && strstr(e, "authorizationStateClosed") != NULL) {
          break;
        }
      }
      return ok ? 0 : 2;
    }
  }
  fprintf(stderr, "no answer from the test DC\n");
  return 1;
}
