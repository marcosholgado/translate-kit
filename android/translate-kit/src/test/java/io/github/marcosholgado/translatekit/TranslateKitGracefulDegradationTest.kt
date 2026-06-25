/*
 * Copyright 2026 Marcos Holgado
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.github.marcosholgado.translatekit

import android.content.Context
import org.junit.Assert.assertFalse
import org.junit.Test
import org.mockito.Mockito.mock

/**
 * Verifies that [TranslateKit.init] degrades gracefully when the native library
 * is absent.
 *
 * translate-kit ships only `arm64-v8a`/`x86_64`, but a host app may also ship
 * `armeabi-v7a`/`x86`; on such a device `System.loadLibrary` throws
 * `UnsatisfiedLinkError`. This JVM test reproduces that exact condition for free
 * — the host JVM has no `libtranslate-kit.so` either — so `init` must catch it
 * and leave the engine uninitialized rather than crashing the caller.
 */
class TranslateKitGracefulDegradationTest {

    @Test
    fun init_withoutNativeLibrary_doesNotThrowAndStaysUninitialized() {
        val context = mock(Context::class.java)

        // Must not throw (UnsatisfiedLinkError is an Error; an uncaught one would
        // crash the host app).
        TranslateKit.init(context)

        assertFalse(
            "init should leave the engine uninitialized when the native library is unavailable",
            TranslateKit.isInitialized(),
        )

        // Idempotent + crash-safe on repeat calls too (no retry storm).
        TranslateKit.init(context)
        assertFalse(TranslateKit.isInitialized())
    }
}
