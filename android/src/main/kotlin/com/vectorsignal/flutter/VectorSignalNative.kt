package com.vectorsignal.flutter

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * Hands native API timings to the Dart SDK over the `vector_signal/native` channel.
 *
 * Calls made before the Dart SDK is ready (app start-up) wait in a small buffer. Only the
 * Flutter engine whose Dart side said "ready" receives events, so background engines
 * (push handlers, workers) never get them. Never throws into the app.
 */
object VectorSignalNative {
    private const val MAX_PENDING = 200

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val lock = Any()
    private val pending = ArrayDeque<Map<String, Any?>>()
    private var activeChannel: MethodChannel? = null

    fun recordApi(name: String, durationMs: Long, success: Boolean, statusCode: Int?) {
        try {
            val call = mapOf(
                "name" to name,
                "durationMs" to durationMs,
                "success" to success,
                "statusCode" to statusCode,
            )
            val channel = synchronized(lock) {
                val active = activeChannel
                if (active == null) {
                    if (pending.size >= MAX_PENDING) pending.removeFirst()
                    pending.addLast(call)
                }
                active
            } ?: return
            send(channel, call)
        } catch (_: Throwable) {
            // Analytics must never break the app's network calls.
        }
    }

    /** The Dart SDK on this engine started: deliver buffered and future events to it. */
    internal fun activate(channel: MethodChannel) {
        val buffered = synchronized(lock) {
            activeChannel = channel
            pending.toList().also { pending.clear() }
        }
        buffered.forEach { send(channel, it) }
    }

    internal fun deactivate(channel: MethodChannel) {
        synchronized(lock) {
            if (activeChannel === channel) activeChannel = null
        }
    }

    private fun send(channel: MethodChannel, call: Map<String, Any?>) {
        mainHandler.post {
            try {
                channel.invokeMethod("api", call)
            } catch (_: Throwable) {
            }
        }
    }
}
