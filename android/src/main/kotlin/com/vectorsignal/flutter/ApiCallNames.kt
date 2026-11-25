package com.vectorsignal.flutter

/**
 * Turns a request into a stable, privacy-safe name such as `GET /api/Agent/{id}`.
 *
 * Only the method and the path are used: never the query string, headers or body.
 * Path segments that look like ids or personal values (anything with a digit or `@`,
 * or very long) become `{id}`, so `/api/Agent/AGA003` and `/api/Agent/AGA004` are one
 * API in the dashboard. Version segments like `v1` are kept.
 *
 * Keep in sync with `api_names.dart` in the Dart SDK.
 */
object ApiCallNames {
    private const val MAX_LENGTH = 200
    private const val MAX_SEGMENT_LENGTH = 40
    private val versionSegment = Regex("^v\\d+$", RegexOption.IGNORE_CASE)

    fun name(method: String, pathSegments: List<String>): String =
        "${method.uppercase()} ${normalizePath(pathSegments)}".take(MAX_LENGTH)

    fun normalizePath(pathSegments: List<String>): String =
        "/" + pathSegments
            .filter { it.isNotEmpty() }
            .joinToString("/") { if (isIdLike(it)) "{id}" else it }

    private fun isIdLike(segment: String): Boolean =
        !versionSegment.matches(segment) &&
            (segment.any { it.isDigit() } || segment.contains('@') || segment.length > MAX_SEGMENT_LENGTH)
}
