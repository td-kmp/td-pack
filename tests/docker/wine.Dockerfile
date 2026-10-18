# Runs the mingwX64 test binaries on non-Windows hosts (pack.sh verify / jni-verify):
# wine for the C and K/N programs, plus a Windows JRE for the JNI test.
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      wine wine64 curl ca-certificates unzip \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/jre.zip \
      "https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse" \
 && unzip -q /tmp/jre.zip -d /opt && mv /opt/jdk-* /opt/jre && rm /tmp/jre.zip
ENV WINEDEBUG=-all WINEPREFIX=/tmp/wineprefix
