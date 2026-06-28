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

/// Result of ``TranslationModel/translate(_:isHtml:)``.
public struct TranslationResult: Equatable {
    /// The translated text or HTML.
    public let text: String
    /// Optional per-sentence quality estimates; `nil` unless a quality model is
    /// loaded and scores are requested.
    public let qualityScores: [Float]?

    public init(text: String, qualityScores: [Float]? = nil) {
        self.text = text
        self.qualityScores = qualityScores
    }
}

/// Result of ``TranslateKit/detectLanguage(_:)``.
public struct LanguageResult: Equatable {
    /// BCP-47-ish language code, e.g. `"en"` (or `"und"` when undetermined).
    public let language: String
    /// Detector confidence in `[0, 1]`.
    public let confidence: Float

    public init(language: String, confidence: Float) {
        self.language = language
        self.confidence = confidence
    }
}
