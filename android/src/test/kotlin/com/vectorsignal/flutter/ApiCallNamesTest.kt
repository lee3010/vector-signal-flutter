package com.vectorsignal.flutter

import kotlin.test.Test
import kotlin.test.assertEquals

class ApiCallNamesTest {
    @Test
    fun keepsWordsAndReplacesIds() {
        assertEquals("GET /api/Agent/{id}", ApiCallNames.name("get", listOf("api", "Agent", "AGA003")))
        assertEquals(
            "POST /api/v1/Payout/{id}/cancel",
            ApiCallNames.name("POST", listOf("api", "v1", "Payout", "6f6602b0e6844572a7afa632d2052eb6", "cancel")),
        )
        assertEquals("GET /api/User/{id}", ApiCallNames.name("GET", listOf("api", "User", "someone@example.com")))
        assertEquals("GET /", ApiCallNames.name("GET", listOf("")))
    }
}
