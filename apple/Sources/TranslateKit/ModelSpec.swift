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

/// Describes one (source -> target) translation model to load.
///
/// All paths point at **decompressed** files on disk (the caller un-gzips
/// Mozilla's `.gz` artifacts). File-path based so the engine can mmap large
/// models, keeping RSS near the on-disk size. Mirrors the Android `ModelSpec`
/// and SPEC-1 §5.
public struct ModelSpec: Equatable {
    /// Source language code, e.g. `"es"`.
    public var sourceLang: String
    /// Target language code, e.g. `"en"`.
    public var targetLang: String
    /// Int8 model, e.g. `model.<pair>.intgemm.alphas.bin`.
    public var modelPath: String
    /// Shared vocab (1) or src+tgt (2) SentencePiece `.spm` files.
    public var vocabPaths: [String]
    /// Lexical shortlist, e.g. `lex.<...>.s2t.bin`.
    public var shortlistPath: String
    /// Path to a pre-generated Bergamot config YAML (produced off-device; see
    /// SPEC-1 §10a). `nil` falls back to the engine's per-architecture defaults.
    public var configYaml: String?
    /// Engine worker threads (>= 1).
    public var numWorkers: Int

    public init(
        sourceLang: String,
        targetLang: String,
        modelPath: String,
        vocabPaths: [String],
        shortlistPath: String,
        configYaml: String? = nil,
        numWorkers: Int = 1
    ) {
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.modelPath = modelPath
        self.vocabPaths = vocabPaths
        self.shortlistPath = shortlistPath
        self.configYaml = configYaml
        self.numWorkers = numWorkers
    }
}
