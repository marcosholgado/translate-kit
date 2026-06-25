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

// Phase A: exercises the C ABI against the stub engine (echo translate, neutral
// language detection). Phase B/C add golden detection/translation cases here.

#include "translate_kit/translate_kit.h"

#include <cstdlib>
#include <string>

#include <gtest/gtest.h>

namespace {

tk_context* MakeContext() {
    tk_context* ctx = nullptr;
    EXPECT_EQ(tk_init(&ctx), TK_OK);
    EXPECT_NE(ctx, nullptr);
    return ctx;
}

tk_model* LoadStubModel(tk_context* ctx) {
    const char* vocab[] = {"/tmp/vocab.spm"};
    tk_model_spec spec = {};
    spec.source_lang = "es";
    spec.target_lang = "en";
    spec.model_path = "/tmp/model.bin";
    spec.vocab_paths = vocab;
    spec.vocab_count = 1;
    spec.shortlist_path = "/tmp/lex.bin";
    spec.config_path = nullptr;
    spec.num_workers = 1;
    tk_model* model = nullptr;
    EXPECT_EQ(tk_load_model(ctx, &spec, &model), TK_OK);
    EXPECT_NE(model, nullptr);
    return model;
}

TEST(CApi, VersionIsNonEmpty) {
    EXPECT_STRNE(tk_version(), "");
}

TEST(CApi, InitRejectsNullOutArg) {
    EXPECT_EQ(tk_init(nullptr), TK_ERR_INVALID_ARG);
}

TEST(CApi, DetectLanguageReturnsResult) {
    tk_context* ctx = MakeContext();
    tk_language_result r = {};
    EXPECT_EQ(tk_detect_language(ctx, "hola mundo", &r), TK_OK);
    EXPECT_STRNE(r.language, "");
    EXPECT_GE(r.confidence, 0.0f);
    EXPECT_LE(r.confidence, 1.0f);
    tk_shutdown(ctx);
}

// Golden language-detection cases against the bundled CLD2 detector. Sentences
// are long enough for CLD2 to score reliably.
TEST(CApi, DetectLanguageGoldens) {
    tk_context* ctx = MakeContext();
    struct Case {
        const char* text;
        const char* expected;
    };
    const Case cases[] = {
        {"This is a simple sentence written in the English language for testing purposes.", "en"},
        {"Esta es una frase sencilla escrita en el idioma español para realizar algunas pruebas.", "es"},
        {"Ceci est une phrase simple écrite en langue française afin d'effectuer quelques tests.", "fr"},
        {"Dies ist ein einfacher Satz, der zu Testzwecken in deutscher Sprache geschrieben wurde.", "de"},
        {"Questa è una frase semplice scritta in lingua italiana per scopi di test e verifica.", "it"},
    };
    for (const Case& c : cases) {
        tk_language_result r = {};
        ASSERT_EQ(tk_detect_language(ctx, c.text, &r), TK_OK) << c.text;
        EXPECT_STREQ(r.language, c.expected) << "text: " << c.text;
        EXPECT_GT(r.confidence, 0.0f) << c.text;
    }
    tk_shutdown(ctx);
}

TEST(CApi, DetectLanguageEmptyIsUnknown) {
    tk_context* ctx = MakeContext();
    tk_language_result r = {};
    EXPECT_EQ(tk_detect_language(ctx, "", &r), TK_OK);
    EXPECT_STREQ(r.language, "und");
    EXPECT_FLOAT_EQ(r.confidence, 0.0f);
    tk_shutdown(ctx);
}

TEST(CApi, DetectLanguageWithoutContextFails) {
    tk_language_result r = {};
    EXPECT_EQ(tk_detect_language(nullptr, "x", &r), TK_ERR_NOT_INITIALIZED);
}

#ifndef TRANSLATEKIT_WITH_ENGINE
TEST(CApi, TranslateEchoesInputInStub) {
    tk_context* ctx = MakeContext();
    tk_model* model = LoadStubModel(ctx);

    const std::string input = "Hola <b>mundo</b>";
    tk_translation_result r = {};
    EXPECT_EQ(tk_translate(model, input.c_str(), /*is_html=*/1, &r), TK_OK);
    ASSERT_NE(r.text, nullptr);
    EXPECT_EQ(std::string(r.text), input);  // stub echoes
    tk_translation_result_free(&r);

    tk_model_close(model);
    tk_shutdown(ctx);
}
#endif  // !TRANSLATEKIT_WITH_ENGINE

#ifdef TRANSLATEKIT_WITH_ENGINE
// Golden translation against a real tiny en->de model. Provide the extracted
// ende.student.tiny11 directory via TK_TEST_MODEL_DIR (see scripts/fetch-models.sh);
// the test is skipped when it is not set.
TEST(CApi, TranslateRealModelEnDe) {
    const char* dir = std::getenv("TK_TEST_MODEL_DIR");
    if (dir == nullptr || dir[0] == '\0') {
        GTEST_SKIP() << "set TK_TEST_MODEL_DIR to the ende.student.tiny11 directory";
    }
    const std::string d(dir);
    const std::string model = d + "/model.intgemm.alphas.bin";
    const std::string vocab = d + "/vocab.deen.spm";
    const std::string lex = d + "/lex.s2t.bin";
    const std::string config = d + "/config.intgemm8bitalpha.yml";
    const char* vocabs[] = {vocab.c_str()};

    tk_context* ctx = MakeContext();
    tk_model_spec spec = {};
    spec.source_lang = "en";
    spec.target_lang = "de";
    spec.model_path = model.c_str();
    spec.vocab_paths = vocabs;
    spec.vocab_count = 1;
    spec.shortlist_path = lex.c_str();
    spec.config_path = config.c_str();
    spec.num_workers = 1;

    tk_model* m = nullptr;
    ASSERT_EQ(tk_load_model(ctx, &spec, &m), TK_OK) << tk_last_error();

    // (a) plain text
    tk_translation_result r = {};
    ASSERT_EQ(tk_translate(m, "Hello World!", /*is_html=*/0, &r), TK_OK) << tk_last_error();
    ASSERT_NE(r.text, nullptr);
    const std::string out(r.text);
    EXPECT_NE(out.find("Hallo"), std::string::npos) << "plain output: " << out;
    tk_translation_result_free(&r);

    // (b) HTML fragment: inline tag must round-trip (detag-and-project)
    tk_translation_result h = {};
    ASSERT_EQ(tk_translate(m, "<b>Hello World!</b>", /*is_html=*/1, &h), TK_OK) << tk_last_error();
    ASSERT_NE(h.text, nullptr);
    const std::string html(h.text);
    EXPECT_NE(html.find("<b>"), std::string::npos) << "html output: " << html;
    EXPECT_NE(html.find("</b>"), std::string::npos) << "html output: " << html;
    tk_translation_result_free(&h);

    tk_model_close(m);
    tk_shutdown(ctx);
}
#endif  // TRANSLATEKIT_WITH_ENGINE

TEST(CApi, LoadModelRejectsMissingModelPath) {
    tk_context* ctx = MakeContext();
    tk_model_spec spec = {};
    spec.source_lang = "es";
    spec.target_lang = "en";
    spec.model_path = nullptr;
    tk_model* model = nullptr;
    EXPECT_EQ(tk_load_model(ctx, &spec, &model), TK_ERR_INVALID_ARG);
    EXPECT_EQ(model, nullptr);
    tk_shutdown(ctx);
}

TEST(CApi, FreeResultIsIdempotentAndNullSafe) {
    tk_translation_result r = {};
    tk_translation_result_free(&r);  // zero-initialized
    tk_translation_result_free(nullptr);
    tk_model_close(nullptr);
    tk_shutdown(nullptr);
}

}  // namespace
