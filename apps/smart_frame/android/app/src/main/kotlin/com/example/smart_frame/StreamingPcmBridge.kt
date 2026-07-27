package com.example.smart_frame

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

class StreamingPcmBridge : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "smart_frame/pcm_stream"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var track: AudioTrack? = null
    private var writtenFrames = 0L
    private var bytesPerFrame = 2

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                val channels = call.argument<Int>("channels") ?: 1
                val volume = (call.argument<Double>("volume") ?: 1.0).toFloat()
                dispatch(result) { start(sampleRate, channels, volume) }
            }
            "write" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.error("invalid_pcm", "PCM bytes are required", null)
                } else {
                    dispatch(result) { write(bytes) }
                }
            }
            "finish" -> dispatch(result) { finish() }
            "cancel" -> dispatch(result) { cancel() }
            else -> result.notImplemented()
        }
    }

    private fun start(sampleRate: Int, channels: Int, volume: Float) {
        release(flush = true)
        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minimum = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minimum, sampleRate * channels * 2 / 5))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        track = builder.build().also {
            it.setVolume(volume.coerceIn(0f, 1f))
            it.play()
        }
        bytesPerFrame = channels * 2
        writtenFrames = 0
    }

    private fun write(bytes: ByteArray) {
        val current = track ?: error("PCM stream has not started")
        var offset = 0
        while (offset < bytes.size) {
            val written = current.write(
                bytes,
                offset,
                bytes.size - offset,
                AudioTrack.WRITE_BLOCKING,
            )
            if (written <= 0) error("AudioTrack write failed: $written")
            offset += written
        }
        writtenFrames += bytes.size / bytesPerFrame
    }

    private fun finish() {
        drain()
        release(flush = false)
    }

    private fun drain() {
        val current = track ?: return
        val remainingFrames = max(0L, writtenFrames - current.playbackHeadPosition.toLong())
        val timeoutMs = min(5_000L, remainingFrames * 1_000L / current.sampleRate + 1_000L)
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (
            current.playState == AudioTrack.PLAYSTATE_PLAYING &&
            current.playbackHeadPosition.toLong() < writtenFrames &&
            System.nanoTime() < deadline
        ) {
            Thread.sleep(5)
        }
    }

    private fun cancel() {
        release(flush = true)
    }

    private fun release(flush: Boolean) {
        val current = track ?: return
        track = null
        writtenFrames = 0
        try {
            if (flush) {
                current.pause()
                current.flush()
            } else if (current.playState == AudioTrack.PLAYSTATE_PLAYING) {
                current.stop()
            }
        } finally {
            current.release()
        }
    }

    private fun dispatch(result: MethodChannel.Result, operation: () -> Unit) {
        executor.execute {
            try {
                operation()
                mainHandler.post { result.success(null) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("pcm_output_failed", error.javaClass.simpleName, null)
                }
            }
        }
    }

    fun dispose() {
        executor.execute { release(flush = true) }
        executor.shutdown()
    }
}
