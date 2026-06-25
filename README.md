# translate-kit

On-device **neural machine translation** + **offline language detection** as a reusable native library.

`translate-kit` wraps the [Bergamot](https://github.com/mozilla/translations) translation engine
(a fork of Marian NMT with quantized int8 student models) and the bundled
[CLD2](https://github.com/CLD2Owners/cld2) Compact Language Detector, and exposes them through a thin,
platform-neutral C ABI. The first platform wrapper is **Android** (JNI → Kotlin, published as a Maven
AAR); the C core is structured so iOS/macOS/Windows wrappers can reuse it later.

CLD2 is self-contained — its language profiles are compiled into the library, so language detection
needs no model file and no network.

> **Privacy:** the library never touches the network. It does no model downloading and consumes only
> on-disk model paths supplied by the caller. Everything stays on-device.

## Status

Early development. Built in phases:

| Phase | Scope | State |
|-------|-------|-------|
| A | Repo scaffold, full public API, publishable AAR (stub native core) | done |
| B | Offline language detection (CLD2, compiled-in) | done |
| C | Bergamot NMT engine integration (HTML-aware translate) | in progress (engine compiles for arm64-v8a) |
| D | Golden tests, third-party license notices, first release | planned |

## Requirements

- **minSdk 28.** Forced by the Bergamot engine: marian's `pathie-cpp` uses `glob()`/`iconv()`, which
  Android bionic only provides at API 28+. Consumers on a lower app minSdk gate the feature off below 28.
- **NDK 28.2.13676358**, CMake 3.22+. Language detection (CLD2) alone has no such floor.

## Repository layout

```
core/        platform-agnostic C++ engine wrapper + the C ABI (include/translate_kit/translate_kit.h)
android/     Android Gradle project — the AAR wrapper (JNI shim + Kotlin facade)
models/      bundled data (sentence-split prefixes) — fetched by scripts/ (Phase C)
scripts/     cross-compile + model-fetch + engine-patch helpers
third_party/ git submodules: cld2 (detector), translations (Bergamot engine); patches/ (engine patches)
```

The translation engine wrapper lives in `core/` and is consumed by every platform wrapper through the
C ABI in `core/include/translate_kit/translate_kit.h`. The Android module builds it via Gradle
`externalNativeBuild` (CMake); other platforms use `scripts/build-*.sh`.

## Building from source

```bash
# 1. Engine submodules (the inference subset is enough for the build):
git submodule update --init --recursive third_party/cld2
git submodule update --init third_party/translations
git -C third_party/translations submodule update --init --recursive \
    inference/3rd_party/ssplit-cpp \
    inference/marian-fork/src/3rd_party/sentencepiece \
    inference/marian-fork/src/3rd_party/intgemm \
    inference/marian-fork/src/3rd_party/ruy \
    inference/marian-fork/src/3rd_party/simd_utils

# 2. Apply translate-kit's local engine patches (see third_party/patches/):
scripts/apply-engine-patches.sh

# 3. Build the AAR (JDK 17/21):
cd android && ./gradlew :translate-kit:assembleRelease
```

## Android usage (Kotlin)

```kotlin
TranslateKit.init(context)                 // loads the native library + inits the engine. Idempotent. Blocking.

val lang = TranslateKit.detectLanguage(text)            // LanguageResult(language, confidence)

val model = TranslateKit.loadModel(
    ModelSpec(
        sourceLang = "es",
        targetLang = "en",
        modelPath = "/…/model.esen.intgemm.alphas.bin",
        vocabPaths = listOf("/…/vocab.esen.spm"),        // 1 (shared) or 2 (src+tgt)
        shortlistPath = "/…/lex.50.50.esen.s2t.bin",
        configYaml = "/…/config.esen.yml",               // pre-generated off-device
    ),
)
val result = model.translate(htmlFragment, isHtml = true)  // inline tags preserved (detag-and-project)
model.close()
```

All native calls are **blocking** — call them off the main thread (e.g. a coroutine on an IO dispatcher).
`translate(input, isHtml = true)` preserves inline HTML tags via the engine's alignment-based
detag-and-project. The library is single-hop per loaded model; non-English↔non-English pairs are pivoted
through English by the caller.

## Coordinates (Maven, GitHub Packages)

```
io.github.marcosholgado:translate-kit-android:<version>
```

## Model-file contract

The library consumes **decompressed** model files (Mozilla ships them gzipped; decompression is the
caller's job) plus a pre-generated Bergamot config YAML. See the model-file contract section below
(populated in Phase C/D) and `SPEC-1 §10a`.

## License

Apache-2.0 (this project). Bundled/linked third-party components retain their own licenses — see
[`NOTICE`](NOTICE) and `THIRD_PARTY_LICENSES.md`.
