# Native/Flutter platform-channel entry points.
# The classes are instantiated from the embedding or registered as a platform
# view, so keep their names and members stable in an R8 release build.
-keep class com.scriptmirror.script_mirror.MainActivity { *; }
-keep class com.scriptmirror.script_mirror.NativeCaptureController { *; }
-keep class com.scriptmirror.script_mirror.NativeAudioCapture { *; }
-keep class com.scriptmirror.script_mirror.CameraPreviewFactory { *; }
-keep class com.scriptmirror.script_mirror.CameraPreviewPlatformView { *; }

# Preserve methods that may be reached by native code in bundled inference or
# Android media libraries without disabling shrinking for the rest of the app.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
