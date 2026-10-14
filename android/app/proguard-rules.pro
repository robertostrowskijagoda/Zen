# Flutter engine and plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# JNI / FFI entry points
-keepclasseswithmembernames class * {
    native <methods>;
}

# WebRTC
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Foreground service plugin
-keep class com.pravera.flutter_foreground_task.** { *; }

# Secure storage / biometrics
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class androidx.biometric.** { *; }
-keep class androidx.security.crypto.** { *; }

# Local auth
-keep class io.flutter.plugins.localauth.** { *; }

# Flutter local notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**

# Incoming-call overlay activity (lock screen / other apps)
-keep class com.roj.zen.IncomingCallActivity { *; }
-keep class com.roj.zen.ZenCallBridge { *; }
