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

import CTranslateKit

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Entry point to translate-kit: on-device neural machine translation + offline
/// language detection. Mirrors the Android `TranslateKit` facade and SPEC-1 §5,
/// over the same platform-neutral C ABI.
///
/// An instance owns one engine context (`tk_context`); its `deinit` tears it
/// down. The bundled language detector (CLD2) is self-contained, so no model
/// file is needed for ``detectLanguage(_:)``. Translation models are supplied by
/// the caller as on-disk paths via ``loadModel(_:)``. The library never touches
/// the network.
///
/// - Important: All calls are **blocking** — call them off the main thread. A
///   `TranslateKit` instance and the ``TranslationModel``s loaded from it are
///   **not** thread-safe: use one from a single background thread at a time
///   (serialize access, e.g. via a dedicated queue or actor).
public final class TranslateKit {

    private let context: OpaquePointer

    /// The library version string, e.g. `"0.1.0"`.
    public static var version: String { String(cString: tk_version()) }

    /// Initializes the engine. Throws if native initialization fails. Blocking.
    public init() throws {
        var context: OpaquePointer?
        try tkCheck(tk_init(&context))
        guard let context else {
            throw TranslateKitError.engine(String(cString: tk_last_error()))
        }
        self.context = context
    }

    deinit {
        tk_shutdown(context)
    }

    /// Detects the language of `text` using the bundled detector. Blocking.
    public func detectLanguage(_ text: String) throws -> LanguageResult {
        var result = tk_language_result()
        let status = text.withCString { tk_detect_language(context, $0, &result) }
        try tkCheck(status)
        let language = withUnsafeBytes(of: result.language) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return LanguageResult(language: language, confidence: result.confidence)
    }

    /// Loads a translation model from on-disk files. Throws on bad/missing
    /// files. Blocking.
    public func loadModel(_ spec: ModelSpec) throws -> TranslationModel {
        // Own every C string for the duration of the call, then hand the C ABI
        // an array of stable pointers (mirrors the Android JNI shim).
        var allocations: [UnsafeMutablePointer<CChar>] = []
        func dup(_ string: String) -> UnsafePointer<CChar> {
            let copy = strdup(string)!
            allocations.append(copy)
            return UnsafePointer(copy)
        }
        defer { for pointer in allocations { free(pointer) } }

        var cSpec = tk_model_spec()
        cSpec.source_lang = dup(spec.sourceLang)
        cSpec.target_lang = dup(spec.targetLang)
        cSpec.model_path = dup(spec.modelPath)
        cSpec.shortlist_path = dup(spec.shortlistPath)
        cSpec.config_path = spec.configYaml.map(dup)
        cSpec.num_workers = Int32(max(1, spec.numWorkers))

        let vocabPointers: [UnsafePointer<CChar>?] = spec.vocabPaths.map(dup)
        var model: OpaquePointer?
        let status: tk_status = vocabPointers.withUnsafeBufferPointer { buffer in
            cSpec.vocab_paths = buffer.baseAddress
            cSpec.vocab_count = buffer.count
            return withUnsafePointer(to: &cSpec) { tk_load_model(context, $0, &model) }
        }
        try tkCheck(status)
        guard let model else {
            throw TranslateKitError.modelLoad(String(cString: tk_last_error()))
        }
        return TranslationModel(handle: model)
    }

    /// Releases a loaded model. Equivalent to ``TranslationModel/close()``.
    public func unloadModel(_ model: TranslationModel) {
        model.close()
    }
}
