package com.scriptmirror.script_mirror

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.view.Surface
import android.media.MediaMetadataRetriever
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalMirrorMode
import androidx.camera.core.MirrorMode
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.core.UseCaseGroup
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.MediaStoreOutputOptions
import androidx.camera.video.PendingRecording
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Native owner for CameraX preview, video encoding and microphone capture.
 * The Flutter UI only talks to this class through MainActivity's channel.
 */
@OptIn(markerClass = [ExperimentalMirrorMode::class])
class NativeCaptureController(private val activity: FlutterActivity) {
    private val mainExecutor = ContextCompat.getMainExecutor(activity)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var cameraProvider: ProcessCameraProvider? = null
    private var previewView: PreviewView? = null
    private var previewUseCase: Preview? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var audioCapture: NativeAudioCapture? = null
    private var pendingStopResult: MethodChannel.Result? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingStartTimeout: Runnable? = null
    private var preparedFrontCamera = true
    private var mirrorPreview = true
    private var preparedQuality = Quality.FHD
    private var preparedAudioEnabled = true
    private var recordingStartedAt = 0L
    private var eventSink: EventChannel.EventSink? = null
    private var audioFeedSink: EventChannel.EventSink? = null
    private var currentPhase = "idle"
    private var interruptionReason: String? = null
    private var lastFinalizedResult: Map<String, Any?>? = null
    private var disposed = false
    private var cameraBindGeneration = 0L
    private var finalizing = false
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private var thermalWarning = false
    private var lastBoundPreviewWidth = 0
    private var lastBoundPreviewHeight = 0
    private var lastBoundPreviewRotation = -1
    private var layoutRebindPosted = false

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) sink.success(mapOf("phase" to currentPhase))
    }

    fun setAudioFeedSink(sink: EventChannel.EventSink?) {
        audioFeedSink = sink
    }

    fun attachPreview(view: PreviewView) {
        previewView = view
        // AndroidView is created before Flutter has necessarily measured it.
        // Delay the first bind until the PreviewView has real dimensions so
        // getViewPort() can describe the actual on-screen crop instead of
        // silently falling back to an uncropped, differently framed stream.
        view.post { bindCameraIfPossible() }
    }

    fun detachPreview(view: PreviewView) {
        if (previewView === view) {
            previewView = null
            layoutRebindPosted = false
            // Invalidate a listener that captured the detached view while the
            // ProcessCameraProvider future was still being resolved.
            cameraBindGeneration++
        }
    }

    /**
     * Rebinds the idle camera when Flutter changes the platform view's size.
     * PreviewView derives its ViewPort from that size, so keeping an old
     * viewport after a portrait/landscape or tablet layout change makes the
     * live frame and saved video use different crops. An active Recording is
     * deliberately left alone; its sensor crop is already fixed for the take.
     */
    fun onPreviewLayoutChanged(view: PreviewView) {
        if (disposed || previewView !== view || view.width <= 0 || view.height <= 0) {
            return
        }
        val rotation = currentDisplayRotation()
        val changed = view.width != lastBoundPreviewWidth ||
            view.height != lastBoundPreviewHeight ||
            rotation != lastBoundPreviewRotation
        if (!changed) return
        if (recording != null) {
            refreshTargetRotation()
            return
        }
        if (previewUseCase == null && videoCapture == null) return
        if (layoutRebindPosted) return
        layoutRebindPosted = true
        view.post {
            layoutRebindPosted = false
            if (!disposed && previewView === view && recording == null) {
                bindCameraIfPossible()
            }
        }
    }

    fun prepare(
        frontCamera: Boolean,
        mirrorPreview: Boolean = true,
        width: Int = 1920,
        height: Int = 1080,
        audioEnabled: Boolean = true,
    ) {
        disposed = false
        preparedFrontCamera = frontCamera
        this.mirrorPreview = mirrorPreview
        preparedQuality = qualityFor(width, height)
        preparedAudioEnabled = audioEnabled
        cleanupStalePendingMedia()
        cleanupStalePendingFiles()
        cleanupStaleAudioFiles()
        startThermalMonitor()
        emitPhase("preparing")
        bindCameraIfPossible()
    }

    fun start(result: MethodChannel.Result) {
        if (disposed) {
            result.error("capture_disposed", "录制服务已关闭", null)
            return
        }
        if (finalizing) {
            result.error("capture_busy", "上一段录制正在保存，请稍候再试", null)
            emitPhase("failed", "capture_busy")
            return
        }
        val capture = videoCapture
        if (recording != null) {
            // A previous page may still own an active Recording while its
            // route is being removed. Treat a second start as busy instead of
            // reporting success and letting the new page lose the real stop
            // handle when the old Finalize callback arrives.
            result.error("capture_busy", "上一段录制仍在结束，请稍候再试", null)
            emitPhase("failed", "capture_busy")
            return
        }
        if (capture == null) {
            pendingStartResult?.error("start_in_progress", "录制启动正在处理中", null)
            pendingStartResult = result
            cancelPendingStartTimeout()
            val timeout = Runnable {
                if (pendingStartResult === result) {
                    pendingStartResult = null
                    result.error("camera_unavailable", "相机尚未准备好", null)
                    emitPhase("failed", "camera_unavailable")
                }
                pendingStartTimeout = null
            }
            pendingStartTimeout = timeout
            // CameraX can need several seconds on older Android releases while
            // it validates the available lens and builds the encoder surface.
            // Keep the pending start alive long enough for that asynchronous
            // initialization, while still failing deterministically if the
            // device never exposes a usable camera.
            mainHandler.postDelayed(timeout, CAMERA_READY_TIMEOUT_MS)
            return
        }
        cancelPendingStartTimeout()
        // A phone can rotate after the preview was bound but before the user
        // taps record. Refresh both use cases immediately before encoding so
        // the file orientation follows the current display.
        refreshTargetRotation()
        startWithMediaStore(capture, result)
    }

    /**
     * Cancels a start that is waiting for CameraX to finish binding its
     * capture use case. There is also a very small hand-off window after
     * CameraX creates a Recording but before Flutter receives the successful
     * platform result. Handle that window here, while the native owner still
     * has an atomic view of the real recording handle.
     *
     * A user cancellation discards the just-started take. A host lifecycle
     * interruption preserves it so Flutter can offer a truthful resume path
     * after the activity returns to the foreground.
     */
    fun cancelStart(preserveRecording: Boolean = false) {
        pendingStartResult?.let { result ->
            pendingStartResult = null
            cancelPendingStartTimeout()
            result.error("capture_cancelled", "录制准备已取消", null)
            emitPhase("failed", "capture_cancelled")
            return
        }

        // If start() already completed the CameraX hand-off, the pending
        // MethodChannel result is gone but recording is now non-null. Do not
        // leave that handle running after Flutter has shown a cancellation
        // state. The Finalize callback below will either retain the result for
        // interruption recovery or delete the cancelled media row.
        val active = recording ?: return
        if (finalizing || interruptionReason != null) return
        interruptionReason = if (preserveRecording) {
            "app_interrupted"
        } else {
            "capture_cancelled"
        }
        emitPhase("stopping", interruptionReason)
        try {
            active.stop()
        } catch (_: Throwable) {
            // CameraX still delivers its final callback on normal devices;
            // dispose() remains a second guarded stop path if it does not.
        }
    }

    private fun startWithMediaStore(capture: VideoCapture<Recorder>, result: MethodChannel.Result) {
        if (!hasEnoughStorage()) {
            emitPhase("failed", "storage_low")
            result.error("storage_low", "可用存储空间不足，至少需要 100 MB", null)
            return
        }
        val stamp = timestamp()
        val legacyPath = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            legacyMediaStorePath(stamp)
        } else {
            null
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && legacyPath == null) {
            // Some Android 9 emulator/storage providers deny direct mkdirs
            // even with WRITE_EXTERNAL_STORAGE. MediaStore can still choose
            // its normal shared-video location when DATA is omitted.
        }
        try {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, "ScriptMirror_$stamp.mp4")
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    // DCIM is indexed consistently by OEM gallery apps. Movies is
                    // valid MediaStore storage, but several gallery views hide it
                    // behind a separate album filter.
                    put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/ScriptMirror")
                } else if (legacyPath != null) {
                    // Android 8/9 do not support RELATIVE_PATH. Supplying DATA
                    // keeps the file in a stable DCIM album for legacy galleries.
                    @Suppress("DEPRECATION")
                    run { put(MediaStore.Video.Media.DATA, legacyPath) }
                }
            }
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
            val options = MediaStoreOutputOptions.Builder(
                activity.contentResolver,
                collection,
            ).setContentValues(values).build()

            val audio = if (preparedAudioEnabled) {
                NativeAudioCapture(
                    context = activity,
                    onPcmFrame = { data, timestampMs ->
                        audioFeedSink?.success(
                            mapOf(
                                "type" to "pcm16",
                                "pcm" to data,
                                "timestampMs" to timestampMs,
                                "sampleRateHz" to NativeAudioCapture.SAMPLE_RATE_HZ,
                                "channels" to NativeAudioCapture.CHANNEL_COUNT,
                            ),
                        )
                    },
                    shouldEmitPcm = { audioFeedSink != null },
                )
            } else {
                null
            }
            if (audio != null && !audio.start()) {
                audio.dispose()
                emitPhase("failed", "audio_unavailable")
                result.error("audio_unavailable", "无法启动共享麦克风音频", null)
                return
            }
            audioCapture = audio
            try {
                // CameraX owns the video surface only. NativeAudioCapture owns the
                // microphone and writes the AAC track that is muxed after stop.
                beginRecording(capture.output.prepareRecording(activity, options), result)
            } catch (error: SecurityException) {
                audioCapture?.stopAndGetFile()?.delete()
                audioCapture = null
                emitPhase("failed", "audio_unavailable")
                result.error("audio_unavailable", "麦克风权限不可用", error.message)
            } catch (error: Exception) {
                audioCapture?.stopAndGetFile()?.delete()
                audioCapture = null
                emitPhase("failed", "recording_unavailable")
                result.error("recording_unavailable", "录制服务暂时不可用", error.message)
            }
        } catch (error: Exception) {
            audioCapture?.stopAndGetFile()?.delete()
            audioCapture = null
            emitPhase("failed", "recording_unavailable")
            result.error("recording_unavailable", "录制服务暂时不可用", error.message)
        }
    }

    /**
     * The encoded video is written to shared external storage while the
     * temporary AAC and ASR files live in the app sandbox. Check both volumes
     * so a full gallery volume cannot be mistaken for a healthy capture path.
     * A provider that refuses StatFs is allowed to make the final MediaStore
     * operation authoritative; we must not invent a low-storage failure.
     */
    @Suppress("DEPRECATION")
    private fun hasEnoughStorage(): Boolean {
        return try {
            val appAvailable = StatFs(activity.filesDir.path).availableBytes
            val mediaAvailable = StatFs(
                Environment.getExternalStorageDirectory().path,
            ).availableBytes
            minOf(appAvailable, mediaAvailable) >= MINIMUM_FREE_BYTES
        } catch (_: Throwable) {
            true
        }
    }

    private fun beginRecording(pending: PendingRecording, result: MethodChannel.Result) {
        // The native audio owner fans out each PCM frame to AAC and ASR.
        interruptionReason = null
        lastFinalizedResult = null
        recordingStartedAt = System.currentTimeMillis()
        emitPhase("recording")
        recording = pending.start(mainExecutor) { event ->
            if (event is VideoRecordEvent.Finalize) {
                val success = !event.hasError()
                val videoUri = event.outputResults.outputUri
                val duration = (System.currentTimeMillis() - recordingStartedAt).coerceAtLeast(0L)
                recording = null
                finalizing = true
                val interruption = interruptionReason
                val cancelled = interruption == "capture_cancelled"
                val audio = audioCapture
                audioCapture = null
                // CameraX's callback runs on the main executor. Muxing and
                // finalizing the shared AAC track must not block Flutter UI.
                Thread {
                    val audioFile = audio?.stopAndGetFile()
                    val combinedUri = if (
                        success && videoUri != Uri.EMPTY && audioFile != null
                    ) {
                        muxVideoAndAudio(videoUri, audioFile)
                    } else {
                        null
                    }
                    audioFile?.delete()
                    if (combinedUri != null && videoUri != Uri.EMPTY) {
                        deleteMediaRow(videoUri)
                    }
                    if (!success && videoUri != Uri.EMPTY) {
                        // MediaStoreOutputOptions can create the row before the
                        // encoder reports its final error. Remove that partial
                        // row so a failed capture never leaves a blank or
                        // broken item in the user's gallery.
                        deleteMediaRow(videoUri)
                    }
                    if (cancelled) {
                        // A user cancellation that lands in the native start
                        // hand-off window must not leave a gallery item. The
                        // mux path may have created a second row, so remove
                        // both the combined output and CameraX's source row.
                        if (combinedUri != null) deleteMediaRow(combinedUri)
                        if (videoUri != Uri.EMPTY) deleteMediaRow(videoUri)
                    }
                    val outputUri = if (success && !cancelled) {
                        combinedUri ?: videoUri.takeUnless { it == Uri.EMPTY }
                    } else {
                        null
                    }
                    val resultPayload = mapOf(
                        "saved" to (success && outputUri != null),
                        "mediaUri" to outputUri?.toString(),
                        "durationMs" to duration,
                        "resolution" to if (success && outputUri != null) {
                            readResolution(outputUri)
                        } else {
                            null
                        },
                        "storageLocation" to if (success && outputUri != null) {
                            readStorageLocation(outputUri)
                        } else {
                            null
                        },
                        "error" to when {
                            cancelled -> "录制准备已取消"
                            !success -> "CameraX 录制失败（错误码 ${event.error}）"
                            success && videoUri == Uri.EMPTY -> "录制没有生成视频文件"
                            combinedUri == null && preparedAudioEnabled ->
                                "视频已保存，但音频合并失败"
                            else -> null
                        },
                        "interrupted" to (interruption != null && !cancelled),
                    )
                    mainExecutor.execute {
                        emitPhase(
                            if (success && !cancelled) "completed" else "failed",
                            when {
                                cancelled -> "capture_cancelled"
                                interruption != null -> interruption
                                else -> if (success) null else "recording_failed"
                            },
                        )
                        if (pendingStopResult == null && interruption != null && !cancelled) {
                            lastFinalizedResult = resultPayload
                        } else {
                            pendingStopResult?.success(resultPayload)
                        }
                        pendingStopResult = null
                        interruptionReason = null
                        finalizing = false
                    }
                }.start()
            }
        }
        result.success(null)
    }

    fun stop(result: MethodChannel.Result) {
        val active = recording
        if (active == null) {
            result.success(mapOf("saved" to false, "error" to "录制尚未开始"))
            return
        }
        if (pendingStopResult != null) {
            result.success(mapOf("saved" to false, "error" to "停止操作已在处理中"))
            return
        }
        pendingStopResult = result
        emitPhase("stopping")
        active.stop()
    }

    /**
     * Android may pause the host while a call, lock screen, camera handoff,
     * or another foreground activity takes ownership of the camera/mic.
     * Finalize the current MediaStore item instead of leaving an open or
     * misleading recording behind. The result is read once by Flutter after
     * the host resumes; a durable script checkpoint covers process death.
     */
    fun onHostPause() {
        val active = recording ?: return
        if (pendingStopResult != null || interruptionReason != null) return
        interruptionReason = "app_interrupted"
        emitPhase("stopping", "app_interrupted")
        active.stop()
    }

    fun onHostResume() {
        refreshTargetRotation()
        // The finalized result is intentionally consumed by Flutter after its
        // lifecycle callback, keeping navigation decisions in the UI layer.
    }

    fun onConfigurationChanged() {
        refreshTargetRotation()
    }

    fun takeFinalizedResult(result: MethodChannel.Result) {
        val finalized = lastFinalizedResult
        lastFinalizedResult = null
        result.success(finalized)
    }

    fun switchCamera() {
        if (recording != null) return
        preparedFrontCamera = !preparedFrontCamera
        bindCameraIfPossible()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        cameraBindGeneration++
        stopThermalMonitor()
        val wasActive = recording != null || pendingStartResult != null
        val activeRecording = recording
        if (activeRecording != null) {
            // A Flutter route can be popped while an explicit Stop call is
            // still waiting for CameraX's Finalize callback. Always issue the
            // native stop here as well; Recording.stop() is idempotent, while
            // merely unbinding the provider can leave the pending result (and
            // the temporary MediaStore row) open on some devices.
            if (pendingStopResult == null && interruptionReason == null) {
                interruptionReason = "capture_disposed"
            }
            emitPhase("stopping", interruptionReason)
            try {
                activeRecording.stop()
            } catch (_: Throwable) {
                // Finalize/error delivery remains the source of truth; dispose
                // must still release the provider and audio resources below.
            }
        } else {
            pendingStopResult?.success(mapOf("saved" to false, "error" to "录制已中断"))
            pendingStopResult = null
        }
        pendingStartResult?.error("capture_disposed", "录制服务已关闭", null)
        pendingStartResult = null
        cancelPendingStartTimeout()
        if (recording == null && audioCapture != null) {
            audioCapture?.stopAndGetFile()?.delete()
            audioCapture = null
        }
        if (wasActive && recording == null) emitPhase("failed", "capture_disposed")
        cameraProvider?.unbindAll()
        cameraProvider = null
        previewUseCase = null
        videoCapture = null
        previewView = null
    }

    /**
     * Thermal status is advisory only. A hot device should not lose a take in
     * progress, so the listener emits a UI hint instead of stopping CameraX.
     * API 28 and below simply have no callback and keep the normal capture
     * path unchanged.
     */
    private fun startThermalMonitor() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || thermalListener != null) {
            return
        }
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            val isWarning = status >= PowerManager.THERMAL_STATUS_SEVERE
            if (isWarning == thermalWarning) return@OnThermalStatusChangedListener
            thermalWarning = isWarning
            emitPhase(
                currentPhase,
                if (isWarning) "thermal_warning" else "thermal_recovered",
            )
        }
        thermalListener = listener
        power.addThermalStatusListener(mainExecutor, listener)
        val initialWarning = power.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE
        if (initialWarning && !thermalWarning) {
            thermalWarning = true
            emitPhase("preparing", "thermal_warning")
        }
    }

    private fun stopThermalMonitor() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
            thermalListener?.let { listener ->
                try {
                    power?.removeThermalStatusListener(listener)
                } catch (_: Throwable) {
                    // Teardown is best effort when the host is being destroyed.
                }
            }
        }
        thermalListener = null
        thermalWarning = false
    }

    private fun bindCameraIfPossible() {
        val view = previewView ?: return
        if (view.width <= 0 || view.height <= 0) {
            view.post {
                if (!disposed && previewView === view) bindCameraIfPossible()
            }
            return
        }
        val generation = ++cameraBindGeneration
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            // CameraX provider creation is asynchronous. The Flutter page can
            // be popped while it is in flight; never bind a fresh camera after
            // the native owner has already been disposed. Likewise, ignore a
            // callback captured by an older PreviewView/configuration when a
            // newer bind request has superseded it.
            if (
                disposed ||
                generation != cameraBindGeneration ||
                previewView !== view
            ) {
                return@addListener
            }
            try {
                cameraProvider = future.get()
                // Bind both use cases to the current physical display rotation.
                // Without an explicit target rotation, devices whose sensor is
                // mounted at a different angle can produce a tilted preview or
                // a file whose transform disagrees with what was recorded.
                val displayRotation = currentDisplayRotation()
                val preview = Preview.Builder()
                    .setTargetRotation(displayRotation)
                    .setMirrorMode(
                        if (preparedFrontCamera && mirrorPreview) {
                            MirrorMode.MIRROR_MODE_ON_FRONT_ONLY
                        } else {
                            MirrorMode.MIRROR_MODE_OFF
                        },
                    )
                    .build().also {
                    it.setSurfaceProvider(view.surfaceProvider)
                }
                val quality = QualitySelector.from(
                    preparedQuality,
                    FallbackStrategy.lowerQualityOrHigherThan(preparedQuality),
                )
                val recorder = Recorder.Builder().setQualitySelector(quality).build()
                val capture = VideoCapture.Builder(recorder)
                    .setTargetRotation(displayRotation)
                    // Keep the encoded front-camera frames in the same
                    // orientation as the selfie viewfinder. This is the
                    // behavior the user expects when reviewing their own
                    // face: the saved take should not appear to change after
                    // leaving the recording screen. Text may consequently be
                    // mirrored, just like it is in a physical mirror.
                    .setMirrorMode(
                        if (preparedFrontCamera && mirrorPreview) {
                            MirrorMode.MIRROR_MODE_ON_FRONT_ONLY
                        } else {
                            MirrorMode.MIRROR_MODE_OFF
                        },
                    )
                    .build()
                cameraProvider?.unbindAll()
                val requestedSelector = CameraSelector.Builder()
                    .requireLensFacing(
                        if (preparedFrontCamera) CameraSelector.LENS_FACING_FRONT
                        else CameraSelector.LENS_FACING_BACK,
                    )
                    .build()
                val provider = cameraProvider
                    ?: throw IllegalStateException("相机服务不可用")
                if (
                    disposed ||
                    generation != cameraBindGeneration ||
                    previewView !== view
                ) {
                    return@addListener
                }
                val selector = when {
                    provider.hasCamera(requestedSelector) -> requestedSelector
                    provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) ->
                        CameraSelector.DEFAULT_BACK_CAMERA
                    provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) ->
                        CameraSelector.DEFAULT_FRONT_CAMERA
                    else -> throw IllegalStateException("设备没有可用摄像头")
                }
                val usingFrontCamera = selector == CameraSelector.DEFAULT_FRONT_CAMERA ||
                    (preparedFrontCamera && selector == requestedSelector)
                // PreviewView fills the whole Flutter surface, whose aspect
                // ratio is usually portrait while the camera quality is 16:9.
                // Binding both use cases to the same ViewPort makes CameraX
                // crop the same sensor area for the live preview and encoded
                // video; without it, the gallery clip can appear shifted or
                // framed differently even though the camera is level.
                val useCaseGroup = UseCaseGroup.Builder()
                    .addUseCase(preview)
                    .addUseCase(capture)
                    .apply {
                        view.getViewPort(displayRotation)?.let(::setViewPort)
                    }
                    .build()
                provider.bindToLifecycle(activity, selector, useCaseGroup)
                lastBoundPreviewWidth = view.width
                lastBoundPreviewHeight = view.height
                lastBoundPreviewRotation = displayRotation
                // Preview.Builder owns the camera transform. Avoid an extra
                // View-level flip, which would double-mirror front-camera
                // frames on API 33+ and make the preview disagree with video.
                // CameraX cannot override Preview mirroring on API 32 and
                // below, so counter its default front-camera mirror only when
                // the user explicitly disabled selfie mirroring there. The
                // recorded VideoCapture uses the same policy above.
                view.scaleX = if (
                    usingFrontCamera &&
                    !mirrorPreview &&
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
                ) {
                    -1f
                } else {
                    1f
                }
                previewUseCase = preview
                videoCapture = capture
                refreshTargetRotation()
                pendingStartResult?.let { result ->
                    pendingStartResult = null
                    cancelPendingStartTimeout()
                    startWithMediaStore(capture, result)
                }
            } catch (_: Exception) {
                // Flutter keeps the manual/timed fallback available when a device
                // cannot initialize CameraX; no recording failure is fabricated here.
                previewUseCase = null
                videoCapture = null
                pendingStartResult?.let { result ->
                    pendingStartResult = null
                    cancelPendingStartTimeout()
                    result.error("camera_unavailable", "相机初始化失败", null)
                }
                emitPhase("failed", "camera_unavailable")
            }
        }, mainExecutor)
    }

    private fun cancelPendingStartTimeout() {
        pendingStartTimeout?.let(mainHandler::removeCallbacks)
        pendingStartTimeout = null
    }

    @Suppress("DEPRECATION")
    private fun currentDisplayRotation(): Int =
        previewView?.display?.rotation ?: activity.windowManager.defaultDisplay.rotation

    private fun refreshTargetRotation() {
        val rotation = currentDisplayRotation()
        previewUseCase?.targetRotation = rotation
        videoCapture?.targetRotation = rotation
    }

    private fun emitPhase(phase: String, reason: String? = null) {
        currentPhase = phase
        val payload = hashMapOf<String, Any?>("phase" to phase)
        if (reason != null) payload["reason"] = reason
        mainExecutor.execute { eventSink?.success(payload) }
    }

    private fun qualityFor(width: Int, height: Int): Quality = when {
        width >= 1920 && height >= 1080 -> Quality.FHD
        width >= 1280 && height >= 720 -> Quality.HD
        else -> Quality.SD
    }

    private fun readResolution(uri: Uri): String? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(activity, uri)
            val width = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
            )
            val height = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
            )
            if (width == null || height == null) {
                null
            } else {
                val rotation = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0
                if (rotation == 90 || rotation == 270) {
                    "${height}×${width}"
                } else {
                    "${width}×${height}"
                }
            }
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    /**
     * Reads the location that the active MediaStore provider actually chose.
     * Android 10+ exposes RELATIVE_PATH; older providers only expose DATA and
     * may ignore the requested path entirely. Never surface an absolute file
     * path to Flutter when the provider does not expose a stable relative one.
     */
    private fun readStorageLocation(uri: Uri): String? {
        val resolver = activity.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return try {
                resolver.query(
                    uri,
                    arrayOf(MediaStore.Video.Media.RELATIVE_PATH),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    cursor.getString(0)?.trim()?.trimEnd('/')?.takeIf { it.isNotEmpty() }
                }
            } catch (_: Exception) {
                null
            }
        }

        @Suppress("DEPRECATION")
        val data = try {
            resolver.query(
                uri,
                arrayOf(MediaStore.Video.Media.DATA),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) null else cursor.getString(0)
            }
        } catch (_: Exception) {
            null
        }
        if (data.isNullOrBlank()) return null
        @Suppress("DEPRECATION")
        val dcimRoot = Environment
            .getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
            .absolutePath
            .trimEnd('/')
        val relativeFile = data.removePrefix("$dcimRoot/")
        if (relativeFile == data) return "系统相册"
        val directory = relativeFile.substringBeforeLast('/', missingDelimiterValue = "")
        return directory.takeIf { it.isNotBlank() }?.let { "DCIM/$it" }
    }

    /**
     * A process killed while CameraX is finalizing can leave an invisible
     * MediaStore pending row behind. Remove only old rows created by this app
     * in its own album; never touch regular gallery media or a current take.
     */
    private fun cleanupStalePendingMedia() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val resolver = activity.contentResolver
        val collection = MediaStore.Video.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val cutoffSeconds = System.currentTimeMillis() / 1_000L - STALE_PENDING_AGE_SECONDS
        try {
            resolver.query(
                collection,
                arrayOf(
                    MediaStore.Video.Media._ID,
                    MediaStore.Video.Media.DISPLAY_NAME,
                    MediaStore.Video.Media.DATE_ADDED,
                ),
                "${MediaStore.Video.Media.IS_PENDING} = 1 AND " +
                    "${MediaStore.Video.Media.RELATIVE_PATH} = ?",
                arrayOf(Environment.DIRECTORY_DCIM + "/ScriptMirror/"),
                null,
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndex(MediaStore.Video.Media._ID)
                val nameColumn = cursor.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
                val dateColumn = cursor.getColumnIndex(MediaStore.Video.Media.DATE_ADDED)
                if (idColumn < 0 || nameColumn < 0 || dateColumn < 0) return@use
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idColumn)
                    val name = cursor.getString(nameColumn).orEmpty()
                    val dateAdded = cursor.getLong(dateColumn)
                    if (
                        id > 0L &&
                        name.startsWith("ScriptMirror_") &&
                        dateAdded in 1 until cutoffSeconds
                    ) {
                        try {
                            resolver.delete(
                                ContentUris.withAppendedId(collection, id),
                                null,
                                null,
                            )
                        } catch (_: Throwable) {
                            // A provider may still be indexing a row; retry on
                            // the next prepare instead of affecting this take.
                        }
                    }
                }
            }
        } catch (_: Throwable) {
            // Cleanup is best effort and must never block a new recording.
        }
    }

    /**
     * Some MediaStore providers remove a failed pending row but leave its
     * hidden temporary file behind. Reclaim only the exact files that this
     * app names in its own DCIM album, and only after they are comfortably
     * older than a normal recording session.
     */
    @Suppress("DEPRECATION")
    private fun cleanupStalePendingFiles() {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
            "ScriptMirror",
        )
        val cutoffMillis = System.currentTimeMillis() - STALE_PENDING_AGE_MILLIS
        try {
            directory.listFiles()?.forEach { file ->
                val name = file.name
                if (
                    file.isFile &&
                    name.startsWith(".pending-") &&
                    name.contains("ScriptMirror_") &&
                    name.endsWith(".mp4") &&
                    file.lastModified() in 1 until cutoffMillis
                ) {
                    try {
                        file.delete()
                    } catch (_: Throwable) {
                        // Best effort; retry on the next prepare.
                    }
                }
            }
        } catch (_: Throwable) {
            // Scoped-storage providers may deny direct directory access; the
            // MediaStore row cleanup above remains the authoritative path.
        }
    }

    /**
     * A process killed while the microphone is being encoded cannot run the
     * normal stop callback, so its app-private AAC file may survive in the
     * cache. Reclaim only old files with the exact NativeAudioCapture prefix;
     * Android may still remove newer cache entries independently.
     */
    private fun cleanupStaleAudioFiles() {
        val cutoffMillis = System.currentTimeMillis() - STALE_PENDING_AGE_MILLIS
        try {
            activity.cacheDir.listFiles()?.forEach { file ->
                val name = file.name
                if (
                    file.isFile &&
                    name.startsWith("scriptmirror-audio-") &&
                    name.endsWith(".mp4") &&
                    file.lastModified() in 1 until cutoffMillis
                ) {
                    try {
                        file.delete()
                    } catch (_: Throwable) {
                        // Best effort; retry on the next prepare.
                    }
                }
            }
        } catch (_: Throwable) {
            // Cache cleanup must never block a new recording.
        }
    }

    /** Combines CameraX's video-only MP4 with the shared native AAC track. */
    private fun muxVideoAndAudio(videoUri: Uri, audioFile: File): Uri? {
        val resolver = activity.contentResolver
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val stamp = timestamp()
        val legacyPath = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            legacyMediaStorePath(stamp)
        } else {
            null
        }
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, "ScriptMirror_${stamp}_audio.mp4")
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_DCIM + "/ScriptMirror")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            } else if (legacyPath != null) {
                @Suppress("DEPRECATION")
                run { put(MediaStore.Video.Media.DATA, legacyPath.replace(".mp4", "_audio.mp4")) }
            }
        }
        val outputUri = resolver.insert(collection, values) ?: return null
        val videoExtractor = MediaExtractor()
        val audioExtractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            videoExtractor.setDataSource(activity, videoUri, null)
            audioExtractor.setDataSource(audioFile.absolutePath)
            val videoTrack = findTrack(videoExtractor, "video/")
            val audioTrack = findTrack(audioExtractor, "audio/")
            if (videoTrack < 0 || audioTrack < 0) throw IllegalStateException("media_track_missing")
            val videoFormat = videoExtractor.getTrackFormat(videoTrack)
            val audioFormat = audioExtractor.getTrackFormat(audioTrack)
            val videoDurationUs = if (videoFormat.containsKey(MediaFormat.KEY_DURATION)) {
                videoFormat.getLong(MediaFormat.KEY_DURATION)
            } else {
                Long.MAX_VALUE
            }
            resolver.openFileDescriptor(outputUri, "w")?.use { descriptor ->
                val activeMuxer = MediaMuxer(
                    descriptor.fileDescriptor,
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
                )
                muxer = activeMuxer
                val muxedVideoTrack = activeMuxer.addTrack(videoFormat)
                val muxedAudioTrack = activeMuxer.addTrack(audioFormat)
                // MediaMuxer does not copy the rotation metadata that CameraX
                // writes to its temporary video. Preserve it before start(),
                // otherwise a portrait recording can play sideways after the
                // shared AAC track is merged.
                videoRotation(videoFormat)?.let { activeMuxer.setOrientationHint(it) }
                activeMuxer.start()
                copyTrack(videoExtractor, videoTrack, activeMuxer, muxedVideoTrack)
                copyTrack(
                    audioExtractor,
                    audioTrack,
                    activeMuxer,
                    muxedAudioTrack,
                    maxPresentationTimeUs = videoDurationUs,
                )
                activeMuxer.stop()
                activeMuxer.release()
                muxer = null
            } ?: throw IllegalStateException("media_output_unavailable")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(
                    outputUri,
                    ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
            }
            return outputUri
        } catch (_: Throwable) {
            try {
                muxer?.release()
            } catch (_: Throwable) {
            }
            deleteMediaRow(outputUri)
            return null
        } finally {
            videoExtractor.release()
            audioExtractor.release()
        }
    }

    private fun findTrack(extractor: MediaExtractor, mimePrefix: String): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith(mimePrefix) == true) return index
        }
        return -1
    }

    /**
     * MediaStore providers are allowed to reject cleanup of a just-finalized
     * row (for example while the gallery is indexing it). Cleanup must never
     * prevent the capture callback from delivering the truthful result.
     */
    private fun deleteMediaRow(uri: Uri) {
        try {
            activity.contentResolver.delete(uri, null, null)
        } catch (_: Throwable) {
            // Best effort. The caller still reports the actual video result.
        }
    }

    private fun videoRotation(format: MediaFormat): Int? {
        if (!format.containsKey(MediaFormat.KEY_ROTATION)) return null
        return format.getInteger(MediaFormat.KEY_ROTATION).let { rotation ->
            when (((rotation % 360) + 360) % 360) {
                0, 90, 180, 270 -> ((rotation % 360) + 360) % 360
                else -> null
            }
        }
    }

    private fun copyTrack(
        extractor: MediaExtractor,
        track: Int,
        muxer: MediaMuxer,
        outputTrack: Int,
        maxPresentationTimeUs: Long = Long.MAX_VALUE,
    ) {
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val requestedSize = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
        } else {
            4 * 1024 * 1024
        }
        val buffer = ByteBuffer.allocateDirect(requestedSize.coerceIn(1 * 1024 * 1024, 16 * 1024 * 1024))
        val info = MediaCodec.BufferInfo()
        var lastPresentationTimeUs = -1L
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            val sampleTimeUs = extractor.sampleTime
            if (sampleTimeUs < 0L) break
            if (sampleTimeUs > maxPresentationTimeUs) break
            // A few camera encoders (especially virtual/emulated cameras)
            // can repeat a timestamp. MediaMuxer requires strictly
            // increasing timestamps per track, so make the smallest possible
            // correction while preserving the original timeline.
            val presentationTimeUs = if (sampleTimeUs <= lastPresentationTimeUs) {
                lastPresentationTimeUs + 1L
            } else {
                sampleTimeUs
            }
            info.offset = 0
            info.size = size
            info.presentationTimeUs = presentationTimeUs
            lastPresentationTimeUs = presentationTimeUs
            // MediaExtractor and MediaCodec intentionally use different flag
            // namespaces. Passing sampleFlags through directly is incorrect
            // and is rejected by lint; preserve only the codec flags that
            // MediaMuxer understands for a copied sample.
            val sampleFlags = extractor.sampleFlags
            info.flags = 0
            if (sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                info.flags = info.flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
            }
            if (sampleFlags and MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME != 0) {
                info.flags = info.flags or MediaCodec.BUFFER_FLAG_PARTIAL_FRAME
            }
            muxer.writeSampleData(outputTrack, buffer, info)
            extractor.advance()
        }
        extractor.unselectTrack(track)
    }

    companion object {
        private const val MINIMUM_FREE_BYTES = 100L * 1024L * 1024L
        private const val CAMERA_READY_TIMEOUT_MS = 10_000L
        private const val STALE_PENDING_AGE_SECONDS = 60L * 60L
        private const val STALE_PENDING_AGE_MILLIS = STALE_PENDING_AGE_SECONDS * 1_000L
    }

    @Suppress("DEPRECATION")
    private fun legacyMediaStorePath(stamp: String): String? {
        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
            "ScriptMirror",
        )
        // mkdirs() returns false when another writer creates the directory
        // between exists() and mkdirs(). Check the final state instead of
        // treating that benign race as a storage failure.
        if (!directory.exists()) directory.mkdirs()
        if (!directory.isDirectory) {
            return null
        }
        return File(directory, "ScriptMirror_$stamp.mp4").absolutePath
    }

    private fun timestamp(): String =
        SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
}
