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
import android.util.Log

/**
 * Entry point to translate-kit: on-device neural machine translation + offline
 * language detection.
 *
 * Usage mirrors a small facade with a lazy [init] driven from the caller's IO
 * dispatcher. All native calls are **blocking**; never call them on the main
 * thread.
 *
 * The library never touches the network. Translation models are supplied by the
 * caller as on-disk paths ([loadModel]); the language detector is bundled and
 * self-contained (no model file to load).
 */
object TranslateKit {

    private const val LIBRARY_NAME = "translate-kit"
    private const val TAG = "TranslateKit"

    @Volatile
    private var nativeContextPtr: Long = 0L

    @Volatile
    private var nativeLibraryUnavailable: Boolean = false

    /**
     * Loads the native library and initializes the engine. Idempotent and
     * crash-safe. Blocking — call from an IO dispatcher.
     *
     * translate-kit ships native libraries for `arm64-v8a` and `x86_64` only. A
     * host app may also ship 32-bit ABIs (`armeabi-v7a`, `x86`), so this can run
     * on a device with no matching `.so`. In that case it degrades gracefully —
     * it does **not** crash the app (an `UnsatisfiedLinkError` is an [Error],
     * which a caller's `Exception` handler would not catch); instead
     * [isInitialized] stays `false` and translation is unavailable on that
     * device. Gate the translation feature on [isInitialized].
     */
    @Synchronized
    fun init(context: Context) {
        if (nativeContextPtr != 0L || nativeLibraryUnavailable) return
        try {
            System.loadLibrary(LIBRARY_NAME)
        } catch (e: UnsatisfiedLinkError) {
            // No native library for this device's ABI. Degrade gracefully rather
            // than crashing the host app; translation stays unavailable here.
            nativeLibraryUnavailable = true
            Log.w(TAG, "translate-kit native library unavailable for this device's ABI; " +
                "on-device translation is disabled here", e)
            return
        }
        val ptr = nativeInit()
        check(ptr != 0L) { "translate-kit init failed: ${nativeLastError()}" }
        nativeContextPtr = ptr
    }

    /**
     * `true` once [init] has loaded the native library and initialized the
     * engine. `false` before [init], or on a device whose ABI translate-kit
     * does not ship a native library for (see [init]).
     */
    fun isInitialized(): Boolean = nativeContextPtr != 0L

    /** Offline language detection using the bundled model. Blocking. */
    fun detectLanguage(text: String): LanguageResult {
        val ptr = nativeContextPtr
        check(ptr != 0L) { "TranslateKit.init(context) must be called before detectLanguage" }
        return nativeDetectLanguage(ptr, text)
    }

    /**
     * Load a translation model from on-disk files. Returns a handle used for
     * subsequent [TranslationModel.translate] calls. Throws on bad/missing
     * files. Blocking.
     */
    fun loadModel(spec: ModelSpec): TranslationModel {
        val ptr = nativeContextPtr
        check(ptr != 0L) { "TranslateKit.init(context) must be called before loadModel" }
        val modelPtr = nativeLoadModel(
            ptr,
            spec.sourceLang,
            spec.targetLang,
            spec.modelPath,
            spec.vocabPaths.toTypedArray(),
            spec.shortlistPath,
            spec.configYaml,
            spec.numWorkers,
        )
        if (modelPtr == 0L) {
            throw IllegalArgumentException("translate-kit loadModel failed: ${nativeLastError()}")
        }
        return TranslationModel(modelPtr)
    }

    /** Releases a loaded model. Equivalent to [TranslationModel.close]. */
    fun unloadModel(model: TranslationModel) {
        model.close()
    }

    private external fun nativeInit(): Long

    private external fun nativeDetectLanguage(nativeContextPtr: Long, text: String): LanguageResult

    private external fun nativeLoadModel(
        nativeContextPtr: Long,
        sourceLang: String,
        targetLang: String,
        modelPath: String,
        vocabPaths: Array<String>,
        shortlistPath: String,
        configPath: String?,
        numWorkers: Int,
    ): Long

    private external fun nativeLastError(): String
}
