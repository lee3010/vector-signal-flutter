package com.vectorsignal.flutter

import java.io.IOException
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Records every call made through an OkHttp client as a Vector Signal `$api` event:
 * method + path (see [ApiCallNames]), HTTP status and time until the response headers arrived.
 * Request and response bodies, headers and query strings are never read.
 *
 * One line in the app's OkHttp setup:
 * ```
 * OkHttpClient.Builder()
 *     .addInterceptor(VectorSignalOkHttpInterceptor())
 * ```
 * Events are handed to the Dart SDK, which batches and sends them. Nothing is sent
 * while the Dart SDK is off (not initialised, disabled or opted out).
 *
 * @param ignoreHosts hosts whose calls are not recorded.
 */
class VectorSignalOkHttpInterceptor @JvmOverloads constructor(
    private val ignoreHosts: Set<String> = emptySet(),
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (request.url.host in ignoreHosts) {
            return chain.proceed(request)
        }

        val name = ApiCallNames.name(request.method, request.url.pathSegments)
        val startNanos = System.nanoTime()
        val response = try {
            chain.proceed(request)
        } catch (e: IOException) {
            // No response at all: offline, timeout, TLS failure.
            VectorSignalNative.recordApi(name, elapsedMs(startNanos), success = false, statusCode = null)
            throw e
        }

        VectorSignalNative.recordApi(
            name,
            elapsedMs(startNanos),
            success = response.code in 200..399,
            statusCode = response.code,
        )
        return response
    }

    private fun elapsedMs(startNanos: Long): Long = (System.nanoTime() - startNanos) / 1_000_000
}
