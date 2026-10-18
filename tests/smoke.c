// Minimal link + runtime check for libtdjson.a: synchronous execute, then a
// real client round-trip through TDLib's actor threads.
#include <stdio.h>
#include <string.h>

#include <td/telegram/td_json_client.h>

int main(void) {
  td_execute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}");

  const char *entities = td_execute(
      "{\"@type\":\"getTextEntities\",\"text\":\"@telegram /test https://telegram.org\"}");
  if (entities == NULL || strstr(entities, "textEntityTypeUrl") == NULL) {
    fprintf(stderr, "getTextEntities failed: %s\n", entities ? entities : "(null)");
    return 1;
  }
  puts(entities);

  int client = td_create_client_id();
  td_send(client, "{\"@type\":\"getOption\",\"name\":\"version\",\"@extra\":42}");
  for (int i = 0; i < 100; i++) {
    const char *event = td_receive(1.0);
    if (event != NULL && strstr(event, "\"@extra\":42") != NULL) {
      puts(event);
      int ok = strstr(event, "optionValueString") != NULL;
      // Wait for the client to close before returning: atexit() tears down
      // OpenSSL, and a TDLib thread still running then aborts in RAND_bytes().
      td_send(client, "{\"@type\":\"close\"}");
      for (int j = 0; j < 30; j++) {
        const char *e = td_receive(1.0);
        if (e != NULL && strstr(e, "authorizationStateClosed") != NULL) {
          break;
        }
      }
      return ok ? 0 : 1;
    }
  }
  fprintf(stderr, "no response to getOption\n");
  return 1;
}
