package com.scriptmirror.script_mirror

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/**
 * Owns the microphone for a capture session and fans out the same PCM frames
 * to the AAC encoder and the optional Flutter ASR feed.
 *
 * CameraX is intentionally configured for video-only output when this class
 * is active. That gives the app one microphone owner instead of asking
 * CameraX and an ASR plugin to compete for the same device input.
 */
class NativeAudioCapture(
    private val context: Context,
    private val onPcmFrame: (data: ByteArray, timestampMs: Long) -> Unit,
    private val shouldEmitPcm: () -> Boolean = { true },
) {
    private val stopRequested = AtomicBoolean(false)
    private val stateLock = Any()
    private var audioRecord: AudioRecord? = null
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var worker: Thread? = null
    private var tempFile: File? = null
    private var sampleRateHz = 16_000
    private var started = false

    /** Starts the microphone and AAC encoder before the camera starts. */
    fun start(): Boolean {
        synchronized(stateLock) {
            if (started) return true
            if (ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.RECORD_AUDIO,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                return false
            }

            return try {
                val record = createAudioRecord()
                // Register each resource immediately. If a later constructor
                // or start call fails, releaseResources() can clean up the
                // objects that were already created instead of leaking them.
                audioRecord = record
                val codec = createEncoder(sampleRateHz)
                encoder = codec
                val file = File.createTempFile("scriptmirror-audio-", ".mp4", context.cacheDir)
                tempFile = file
                val audioMuxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                muxer = audioMuxer

                record.startRecording()
                codec.start()
                stopRequested.set(false)
                started = true
                worker = Thread(::runCapture, "ScriptMirrorAudio").also { it.start() }
                true
            } catch (_: Throwable) {
                releaseResources(deleteTemp = true)
                false
            }
        }
    }

    /**
     * Stops capture, finishes the audio-only MP4 and returns it for muxing
     * with CameraX's video-only output. The method is safe to call repeatedly.
     */
    fun stopAndGetFile(): File? {
        val thread: Thread?
        synchronized(stateLock) {
            if (!started) return tempFile?.takeIf { it.exists() }
            stopRequested.set(true)
            try {
                audioRecord?.stop()
            } catch (_: Throwable) {
                // The worker still drains the encoder and releases resources.
            }
            thread = worker
        }

        if (thread != null && thread !== Thread.currentThread()) {
            try {
                thread.join(STOP_JOIN_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }

        synchronized(stateLock) {
            val output = tempFile?.takeIf { it.exists() && it.length() > 0L }
            releaseResources(deleteTemp = output == null)
            return output
        }
    }

    fun dispose() {
        stopAndGetFile()?.delete()
    }

    private fun createAudioRecord(): AudioRecord {
        // Keep the guard local to the constructor call as well as in start().
        // Android can revoke a runtime microphone permission between those two
        // points; failing here lets the caller degrade cleanly instead of
        // crashing inside AudioRecord's permission-gated constructor.
        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("record_audio_permission_missing")
        }
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val preferredSources = intArrayOf(
            MediaRecorder.AudioSource.CAMCORDER,
            MediaRecorder.AudioSource.MIC,
        )
        var lastError: Throwable? = null
        for (source in preferredSources) {
            try {
                val minimum = AudioRecord.getMinBufferSize(
                    sampleRateHz,
                    channelConfig,
                    encoding,
                )
                if (minimum <= 0) throw IllegalStateException("audio_buffer_unavailable")
                val bufferSize = max(minimum, sampleRateHz / 5 * BYTES_PER_SAMPLE)
                val record = AudioRecord(
                    source,
                    sampleRateHz,
                    channelConfig,
                    encoding,
                    bufferSize,
                )
                if (record.state == AudioRecord.STATE_INITIALIZED) return record
                record.release()
                lastError = IllegalStateException("audio_record_not_initialized")
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError ?: IllegalStateException("audio_record_unavailable")
    }

    private fun createEncoder(rate: Int): MediaCodec {
        val format = MediaFormat.createAudioFormat(AUDIO_MIME, rate, CHANNEL_COUNT)
        format.setInteger(
            MediaFormat.KEY_AAC_PROFILE,
            MediaCodecInfo.CodecProfileLevel.AACObjectLC,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, rate / 5 * BYTES_PER_SAMPLE)
        return MediaCodec.createEncoderByType(AUDIO_MIME).also {
            it.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
    }

    private fun runCapture() {
        val record = audioRecord ?: return
        val codec = encoder ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        val pcmBuffer = ByteArray(sampleRateHz / 5 * BYTES_PER_SAMPLE)
        var totalSamples = 0L
        val encoderState = EncoderState()

        try {
            while (!stopRequested.get()) {
                val read = record.read(pcmBuffer, 0, pcmBuffer.size, AudioRecord.READ_BLOCKING)
                if (read <= 0) {
                    if (read == AudioRecord.ERROR_DEAD_OBJECT) break
                    continue
                }
                val timestampUs = totalSamples * 1_000_000L / sampleRateHz
                totalSamples += read / BYTES_PER_SAMPLE
                queueInput(codec, pcmBuffer, read, timestampUs, encoderState)
                if (shouldEmitPcm()) {
                    try {
                        onPcmFrame(pcmBuffer.copyOf(read), timestampUs / 1_000L)
                    } catch (_: Throwable) {
                        // A disconnected EventChannel must not stop video capture.
                    }
                }
                drainEncoder(codec, bufferInfo, encoderState)
            }

            if (queueEndOfStream(codec, totalSamples * 1_000_000L / sampleRateHz, encoderState)) {
                while (true) {
                    val outputIndex = codec.dequeueOutputBuffer(bufferInfo, CODEC_TIMEOUT_US)
                    if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        updateFormat(codec.outputFormat, encoderState)
                    } else if (outputIndex >= 0) {
                        val isCodecConfig =
                            bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (
                            bufferInfo.size > 0 &&
                            !isCodecConfig &&
                            encoderState.track >= 0 &&
                            encoderState.muxerStarted
                        ) {
                            codec.getOutputBuffer(outputIndex)?.let { encoded ->
                                writeSample(encoderState.track, encoded, bufferInfo)
                            }
                        }
                        val end = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        codec.releaseOutputBuffer(outputIndex, false)
                        if (end) break
                    }
                }
            }
        } catch (_: Throwable) {
            // The video result remains truthful even if the optional audio
            // encoder fails; the caller can retain the video-only file.
        } finally {
            synchronized(stateLock) {
                try {
                    if (encoderState.muxerStarted) muxer?.stop()
                } catch (_: Throwable) {
                    // A zero-sample or interrupted muxer cannot be stopped.
                }
                try {
                    muxer?.release()
                } catch (_: Throwable) {
                }
                muxer = null
            }
        }
    }

    private fun queueInput(
        codec: MediaCodec,
        pcm: ByteArray,
        size: Int,
        timestampUs: Long,
        state: EncoderState,
    ) {
        var index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
        var attempts = 0
        while (index < 0 && attempts++ < 4 && !stopRequested.get()) {
            drainEncoder(codec, MediaCodec.BufferInfo(), state)
            index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
        }
        if (index < 0) return
        val input = codec.getInputBuffer(index) ?: return
        input.clear()
        input.put(pcm, 0, size)
        codec.queueInputBuffer(index, 0, size, timestampUs, 0)
    }

    private fun queueEndOfStream(codec: MediaCodec, timestampUs: Long, state: EncoderState): Boolean {
        var index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
        var attempts = 0
        while (index < 0 && attempts++ < 20) {
            drainEncoder(codec, MediaCodec.BufferInfo(), state)
            index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
        }
        if (index < 0) return false
        codec.queueInputBuffer(
            index,
            0,
            0,
            timestampUs,
            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
        )
        return true
    }

    private fun drainEncoder(
        codec: MediaCodec,
        info: MediaCodec.BufferInfo,
        state: EncoderState,
    ) {
        while (true) {
            when (val outputIndex = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    updateFormat(codec.outputFormat, state)
                }
                else -> if (outputIndex >= 0) {
                    val isCodecConfig =
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (
                        info.size > 0 &&
                        !isCodecConfig &&
                        state.track >= 0 &&
                        state.muxerStarted
                    ) {
                        codec.getOutputBuffer(outputIndex)?.let { encoded ->
                            writeSample(state.track, encoded, info)
                        }
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                }
            }
        }
    }

    private fun updateFormat(format: MediaFormat, state: EncoderState) {
        if (state.track >= 0) return
        state.track = muxer?.addTrack(format) ?: -1
        if (state.track >= 0 && !state.muxerStarted) {
            muxer?.start()
            state.muxerStarted = true
        }
    }

    private fun writeSample(track: Int, source: ByteBuffer, info: MediaCodec.BufferInfo) {
        val output = source.duplicate()
        output.position(info.offset)
        output.limit(info.offset + info.size)
        muxer?.writeSampleData(track, output, info)
    }

    private class EncoderState {
        var track: Int = -1
        var muxerStarted: Boolean = false
    }

    private fun releaseResources(deleteTemp: Boolean) {
        try {
            audioRecord?.release()
        } catch (_: Throwable) {
        }
        audioRecord = null
        try {
            encoder?.stop()
        } catch (_: Throwable) {
        }
        try {
            encoder?.release()
        } catch (_: Throwable) {
        }
        encoder = null
        try {
            muxer?.release()
        } catch (_: Throwable) {
        }
        muxer = null
        worker = null
        started = false
        if (deleteTemp) tempFile?.delete()
        if (deleteTemp || tempFile?.exists() == false) tempFile = null
    }

    companion object {
        const val SAMPLE_RATE_HZ = 16_000
        const val CHANNEL_COUNT = 1
        private const val DEFAULT_SAMPLE_RATE_HZ = 16_000
        private const val BYTES_PER_SAMPLE = 2
        private const val AUDIO_BIT_RATE = 64_000
        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val CODEC_TIMEOUT_US = 10_000L
        private const val STOP_JOIN_TIMEOUT_MS = 4_000L
    }
}
