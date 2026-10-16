/*
 * Platform part of the JNI headers for every target td-pack builds.
 *
 * jni.h is target-independent and comes from the host JDK, but its
 * jni_md.h is per OS (include/<os>/), and cross builds (e.g. mingwX64 on a
 * Linux host) must not pick the host's: on Windows `long` is 32-bit, so a
 * Linux jni_md.h would make jlong 32-bit. This header is put first on the
 * include path and mirrors the JDK's darwin/linux/win32 variants.
 */
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#ifdef _WIN32
#define JNIEXPORT __declspec(dllexport)
#define JNIIMPORT __declspec(dllimport)
#define JNICALL __stdcall
typedef long jint;
typedef __int64 jlong;
#else
#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT __attribute__((visibility("default")))
#define JNICALL
typedef int jint;
#ifdef _LP64
typedef long jlong;
#else
typedef long long jlong;
#endif
#endif

typedef signed char jbyte;

#endif /* !_JAVASOFT_JNI_MD_H_ */
