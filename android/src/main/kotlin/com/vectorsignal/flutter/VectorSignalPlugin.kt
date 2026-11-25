package com.vectorsignal.flutter

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.Executors
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the `vector_signal/native` channel: API calls from [VectorSignalOkHttpInterceptor]
 * and WebP encoding of session-replay frames.
 */
class VectorSignalPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val channel = channel
        when (call.method) {
            // The Dart SDK on this engine started (or stopped).
            "ready" -> {
                if (channel != null) VectorSignalNative.activate(channel)
                result.success(null)
            }
            "stop" -> {
                if (channel != null) VectorSignalNative.deactivate(channel)
                result.success(null)
            }
            // Session replay: compress a masked frame off the main thread.
            "encodeWebp" -> {
                val rgba = call.argument<ByteArray>("rgba")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val quality = call.argument<Int>("quality") ?: 50
                if (rgba == null) {
                    result.error("bad_args", "rgba is required", null)
                    return
                }
                encoder.execute {
                    try {
                        val webp = ReplayImageEncoder.encodeWebp(rgba, width, height, quality)
                        mainHandler.post { result.success(webp) }
                    } catch (e: Throwable) {
                        mainHandler.post { result.error("encode_failed", e.message, null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.let {
            VectorSignalNative.deactivate(it)
            it.setMethodCallHandler(null)
        }
        channel = null
    }

    companion object {
        const val CHANNEL = "vector_signal/native"

        /** One background thread: frames are encoded one at a time, never on the UI thread. */
        private val encoder = Executors.newSingleThreadExecutor { r ->
            Thread(r, "vector-signal-replay").apply { isDaemon = true }
        }
        private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    }
}
