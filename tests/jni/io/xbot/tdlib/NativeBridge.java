package io.xbot.tdlib;

/** Test-side mirror of the natives td_jni.cpp registers (patches/native-bridge-jni.patch). */
public final class NativeBridge {
  public interface LogMessageHandler {
    void onLogMessage(int verbosityLevel, String message);
  }

  public static native int nativeCreateClientId();

  public static native void nativeSend(int clientId, String request);

  public static native String nativeReceive(double timeout);

  public static native String nativeExecute(String request);

  public static native void nativeSetLogMessageHandler(int maxVerbosityLevel, LogMessageHandler handler);

  private NativeBridge() {}
}
