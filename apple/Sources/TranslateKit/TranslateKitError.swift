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

/// Errors thrown by ``TranslateKit`` and ``TranslationModel``. Each case maps to
/// a `tk_status` from the C ABI and carries the engine's last-error message.
public enum TranslateKitError: Error, Equatable {
    /// A required argument was null or empty (`TK_ERR_INVALID_ARG`).
    case invalidArgument(String)
    /// The engine context was not initialized (`TK_ERR_NOT_INITIALIZED`).
    case notInitialized(String)
    /// A model/config/vocab file was missing or unreadable (`TK_ERR_IO`).
    case io(String)
    /// The engine rejected the model/config (`TK_ERR_MODEL_LOAD`).
    case modelLoad(String)
    /// Translation failed at runtime (`TK_ERR_TRANSLATE`).
    case translation(String)
    /// An unexpected engine/internal error (`TK_ERR_INTERNAL`).
    case engine(String)

    init(status: tk_status, message: String) {
        let detail = message.isEmpty ? "translate-kit error" : message
        if status == TK_ERR_INVALID_ARG {
            self = .invalidArgument(detail)
        } else if status == TK_ERR_NOT_INITIALIZED {
            self = .notInitialized(detail)
        } else if status == TK_ERR_IO {
            self = .io(detail)
        } else if status == TK_ERR_MODEL_LOAD {
            self = .modelLoad(detail)
        } else if status == TK_ERR_TRANSLATE {
            self = .translation(detail)
        } else {
            self = .engine(detail)
        }
    }
}

/// Throws a ``TranslateKitError`` (with the engine's last-error message) unless
/// `status` is `TK_OK`.
@inline(__always)
func tkCheck(_ status: tk_status) throws {
    guard status != TK_OK else { return }
    throw TranslateKitError(status: status, message: String(cString: tk_last_error()))
}
