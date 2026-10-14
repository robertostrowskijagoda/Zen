//go:build android

package main

/*
#include <jni.h>

__attribute__((used, visibility("default")))
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
	return JNI_VERSION_1_6;
}
*/
import "C"
