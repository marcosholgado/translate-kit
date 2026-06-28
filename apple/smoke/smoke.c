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

/*
 * C-ABI smoke test for the Apple build slices.
 *
 * Purpose: prove that an Apple slice of translate-kit (the platform-neutral core
 * + the vendored Bergamot engine) links and runs through the public C ABI alone
 * — the same surface the Swift wrapper will sit on. It is built twice by
 * scripts/build-apple.sh: once as a normal CMake target (proves the CMake target
 * graph links), then re-linked by hand against the single MERGED static archive
 * (libtranslatekit.a) that the XCFramework will ship (proves that archive is
 * symbol-complete with no missing engine objects).
 *
 * It always REFERENCES the engine entry points (tk_load_model / tk_translate) so
 * those symbols must resolve at link time even on a host with no test model. When
 * TK_TEST_MODEL_DIR points at an extracted ende.student.tiny11 directory it also
 * runs a live en->de translation and asserts the output, mirroring the gtest
 * golden (CApi.TranslateRealModelEnDe).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "translate_kit/translate_kit.h"

/* Force the engine entry points to be referenced (and thus linked) regardless of
 * whether the live-translation path below runs. Taking their addresses pulls the
 * c_api.cpp objects, which transitively require the whole marian/bergamot chain —
 * exactly the symbols we want to prove are present in the merged archive. */
static void* volatile g_engine_symbol_refs[] = {
    (void*)&tk_load_model,
    (void*)&tk_translate,
    (void*)&tk_translation_result_free,
    (void*)&tk_model_close,
};

static int run_live_translation(tk_context* ctx, const char* dir) {
    char model[1024], vocab[1024], lex[1024], config[1024];
    snprintf(model, sizeof(model), "%s/model.intgemm.alphas.bin", dir);
    snprintf(vocab, sizeof(vocab), "%s/vocab.deen.spm", dir);
    snprintf(lex, sizeof(lex), "%s/lex.s2t.bin", dir);
    snprintf(config, sizeof(config), "%s/config.intgemm8bitalpha.yml", dir);
    const char* vocabs[] = {vocab};

    tk_model_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.source_lang = "en";
    spec.target_lang = "de";
    spec.model_path = model;
    spec.vocab_paths = vocabs;
    spec.vocab_count = 1;
    spec.shortlist_path = lex;
    spec.config_path = config;
    spec.num_workers = 1;

    tk_model* m = NULL;
    if (tk_load_model(ctx, &spec, &m) != TK_OK || m == NULL) {
        fprintf(stderr, "tk_load_model failed: %s\n", tk_last_error());
        return 1;
    }

    tk_translation_result r;
    memset(&r, 0, sizeof(r));
    if (tk_translate(m, "Hello World!", /*is_html=*/0, &r) != TK_OK) {
        fprintf(stderr, "tk_translate failed: %s\n", tk_last_error());
        tk_model_close(m);
        return 1;
    }

    printf("translate(\"Hello World!\") -> %s\n", r.text ? r.text : "(null)");
    const int ok = (r.text != NULL && strstr(r.text, "Hallo") != NULL);
    tk_translation_result_free(&r);
    tk_model_close(m);

    if (!ok) {
        fprintf(stderr, "expected translation to contain 'Hallo'\n");
        return 1;
    }
    return 0;
}

int main(void) {
    (void)g_engine_symbol_refs;

    printf("translate-kit version: %s\n", tk_version());

    tk_context* ctx = NULL;
    if (tk_init(&ctx) != TK_OK || ctx == NULL) {
        fprintf(stderr, "tk_init failed: %s\n", tk_last_error());
        return 1;
    }

    /* Language detection (CLD2, always available, no model file). */
    tk_language_result lr;
    memset(&lr, 0, sizeof(lr));
    const char* sample = "Esta es una frase escrita en espanol para detectar el idioma.";
    if (tk_detect_language(ctx, sample, &lr) != TK_OK) {
        fprintf(stderr, "tk_detect_language failed: %s\n", tk_last_error());
        tk_shutdown(ctx);
        return 1;
    }
    printf("detect -> %s (%.3f)\n", lr.language, lr.confidence);
    if (strcmp(lr.language, "es") != 0) {
        fprintf(stderr, "expected detected language 'es', got '%s'\n", lr.language);
        tk_shutdown(ctx);
        return 1;
    }

    /* Translation (engine). Run live only when a test model is supplied; the
     * symbols are referenced unconditionally above so the link is exercised
     * either way. */
    const char* dir = getenv("TK_TEST_MODEL_DIR");
    if (dir != NULL && dir[0] != '\0') {
        if (run_live_translation(ctx, dir) != 0) {
            tk_shutdown(ctx);
            return 1;
        }
    } else {
        printf("TK_TEST_MODEL_DIR not set; skipped live translation "
               "(engine symbols still linked).\n");
    }

    tk_shutdown(ctx);
    printf("SMOKE OK\n");
    return 0;
}
