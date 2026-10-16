import io.xbot.tdlib.NativeBridge;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** usage: JniSmoke <path to libtdjsonjava> */
public final class JniSmoke {
  public static void main(String[] args) throws Exception {
    System.load(new java.io.File(args[0]).getAbsolutePath());

    NativeBridge.nativeExecute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}");

    // Log message handler: addLogMessage must reach it.
    CountDownLatch logged = new CountDownLatch(1);
    NativeBridge.nativeSetLogMessageHandler(1, (level, message) -> {
      if (message.contains("td-pack-jni-log-check")) {
        logged.countDown();
      }
    });
    NativeBridge.nativeExecute(
        "{\"@type\":\"addLogMessage\",\"verbosity_level\":1,\"text\":\"td-pack-jni-log-check\"}");
    check(logged.await(5, TimeUnit.SECONDS), "log message handler was not called");
    NativeBridge.nativeSetLogMessageHandler(0, null);

    String entities = NativeBridge.nativeExecute(
        "{\"@type\":\"getTextEntities\",\"text\":\"@telegram /test https://telegram.org\"}");
    check(entities != null && entities.contains("textEntityTypeUrl"), "getTextEntities: " + entities);

    int client = NativeBridge.nativeCreateClientId();
    NativeBridge.nativeSend(client, "{\"@type\":\"getOption\",\"name\":\"version\",\"@extra\":42}");
    for (int i = 0; i < 100; i++) {
      String event = NativeBridge.nativeReceive(1.0);
      if (event != null && event.contains("\"@extra\":42")) {
        System.out.println(event);
        check(event.contains("optionValueString"), "getOption: " + event);
        // Let TDLib shut down before the JVM exits.
        NativeBridge.nativeSend(client, "{\"@type\":\"close\"}");
        for (int j = 0; j < 30; j++) {
          String e = NativeBridge.nativeReceive(1.0);
          if (e != null && e.contains("authorizationStateClosed")) {
            break;
          }
        }
        System.out.println("log handler: ok");
        return;
      }
    }
    throw new AssertionError("no response to getOption");
  }

  private static void check(boolean condition, String message) {
    if (!condition) {
      throw new AssertionError(message);
    }
  }
}
