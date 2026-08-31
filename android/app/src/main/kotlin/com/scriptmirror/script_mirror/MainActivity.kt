package com.scriptmirror.script_mirror

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var captureController: NativeCaptureController
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        captureController = NativeCaptureController(this)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            CAMERA_VIEW_TYPE,
            CameraPreviewFactory(captureController),
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAPTURE_CHANNEL)
            .setMethodCallHandler { call, result -> handleCaptureCall(call, result) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CAPTURE_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    captureController.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    captureController.setEventSink(null)
                }
            })
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_FEED_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    captureController.setAudioFeedSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    captureController.setAudioFeedSink(null)
                }
            })
    }

    private fun handleCaptureCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestCapturePermissions(result)
            "permissionsGranted" -> result.success(hasCapturePermissions())
            "takeFinalizedResult" -> captureController.takeFinalizedResult(result)
            "openMedia" -> openMedia(call, result)
            "openAppSettings" -> openAppSettings(result)
            "prepare" -> {
                val frontCamera = (call.argument<Boolean>("frontCamera") ?: true)
                val mirrorPreview = (call.argument<Boolean>("mirrorPreview") ?: true)
                val width = call.argument<Int>("width") ?: 1920
                val height = call.argument<Int>("height") ?: 1080
                val audioEnabled = (call.argument<Boolean>("audioEnabled") ?: true)
                captureController.prepare(
                    frontCamera,
                    mirrorPreview,
                    width,
                    height,
                    audioEnabled,
                )
                result.success(null)
            }
            "start" -> {
                captureController.start(result)
            }
            "cancelStart" -> {
                val preserveRecording = call.argument<Boolean>("preserveRecording") ?: false
                captureController.cancelStart(preserveRecording)
                result.success(null)
            }
            "stop" -> captureController.stop(result)
            "switchCamera" -> {
                captureController.switchCamera()
                result.success(null)
            }
            "dispose" -> {
                captureController.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onPause() {
        if (::captureController.isInitialized) captureController.onHostPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (::captureController.isInitialized) captureController.onHostResume()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (::captureController.isInitialized) {
            captureController.onConfigurationChanged()
        }
    }

    private fun openMedia(call: MethodCall, result: MethodChannel.Result) {
        val rawUri = call.argument<String>("uri")
        if (rawUri.isNullOrBlank()) {
            result.success(false)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(rawUri), "video/mp4")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            )
            startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun requestCapturePermissions(result: MethodChannel.Result) {
        val required = requiredCapturePermissions()
        val missing = required.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermissionResult?.error("permission_in_progress", "权限请求正在进行", null)
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    private fun hasCapturePermissions(): Boolean = requiredCapturePermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun requiredCapturePermissions(): List<String> = buildList {
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    override fun onDestroy() {
        if (::captureController.isInitialized) captureController.dispose()
        super.onDestroy()
    }

    companion object {
        const val CAPTURE_CHANNEL = "scriptmirror/capture"
        const val CAPTURE_EVENTS_CHANNEL = "scriptmirror/capture_events"
        const val AUDIO_FEED_CHANNEL = "scriptmirror/audio_feed"
        const val CAMERA_VIEW_TYPE = "scriptmirror.camera_preview"
        private const val PERMISSION_REQUEST_CODE = 4107
    }
}
