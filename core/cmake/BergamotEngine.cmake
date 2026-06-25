# Copyright 2026 Marcos Holgado
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds the Bergamot translation engine and wires it into translate-kit.
#
# This module is where ALL of the engine's per-architecture / per-compiler quirks
# live, so the rest of core/ stays platform-neutral. It keys off the target
# ARCHITECTURE (not any particular OS), so the same logic serves Android arm64,
# Apple Silicon, Windows, and x86_64:
#   - arm64  -> marian's ruy + simde path (needs the ARM/FMA/SSE defines + <fenv.h>)
#   - x86_64 -> marian's intgemm/AVX2 path
#
# Public API:
#   translatekit_add_engine(<engine_dir>)          configure + build engine targets
#   translatekit_link_engine(<target> <engine_dir>) link the engine into <target>

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
    set(TRANSLATEKIT_ARCH_ARM TRUE)
else()
    set(TRANSLATEKIT_ARCH_ARM FALSE)
endif()

# marian enables its ARM SIMD path (simde) via the ARM/FMA/SSE defines, and the
# simde headers also need <fenv.h>. marian scopes these to its OWN targets; any
# other target that includes marian headers needs them too. We apply them
# per-target (never globally) so unrelated C dependencies — zlib, pcre2 — are not
# compiled with these defines, which would break their use of system headers
# (e.g. against the macOS SDK).
function(_translatekit_apply_marian_arch_flags target)
    if(TRANSLATEKIT_ARCH_ARM AND TARGET ${target})
        target_compile_definitions(${target} PRIVATE ARM FMA SSE)
        target_compile_options(${target} PRIVATE -include fenv.h)
    endif()
endfunction()

function(translatekit_add_engine engine_dir)
    if(NOT EXISTS ${engine_dir}/CMakeLists.txt)
        message(FATAL_ERROR
            "TRANSLATEKIT_WITH_ENGINE=ON but the engine is missing at ${engine_dir}.\n"
            "Run: git submodule update --init --recursive third_party/translations\n"
            "Then: scripts/apply-engine-patches.sh")
    endif()

    # Engine build knobs (shared across platforms).
    set(SSPLIT_USE_INTERNAL_PCRE2 ON CACHE BOOL "" FORCE)  # build PCRE2 for the target
    set(COMPILE_TESTS OFF CACHE BOOL "" FORCE)
    set(COMPILE_UNIT_TESTS OFF CACHE BOOL "" FORCE)

    # Pin the target CPU so marian never probes the build host (wrong when
    # cross-compiling, e.g. for Android). On a native build the engine's own
    # detection is correct, so we leave BUILD_ARCH alone.
    if(ANDROID)
        if(TRANSLATEKIT_ARCH_ARM)
            # Real phones: marian's ruy/NEON int8 path.
            set(BUILD_ARCH "armv8-a" CACHE STRING "" FORCE)
        else()
            # x86_64 emulator/CI: marian's intgemm path. Pin x86-64-v2 (SSE3/SSSE3/
            # SSE4.2, no AVX) so marian compiles with a valid target -march (never
            # the arm64 build host's "native") AND its own code never emits AVX
            # instructions that SIGILL on an AVX2-less x86 emulator. We deliberately
            # do NOT pin AVX2 here: intgemm runtime-dispatches its AVX2/SSSE3 int8
            # kernels via CPUID independent of this -march, so the int8 hot path
            # still uses AVX2 where the CPU has it — pinning v2 costs nothing there
            # and buys emulator/CI robustness (the classic AVX-on-emulator SIGILL).
            set(BUILD_ARCH "x86-64-v2" CACHE STRING "" FORCE)
        endif()
    endif()

    # marian needs a float32 GEMM (sgemm) for batched products (attention). On
    # ARM it routes sgemm through ruy (marian sets USE_RUY_SGEMM itself). On x86
    # it expects MKL/OpenBLAS, and with neither present marian's fallback sgemm is
    # a stub that aborts at the first translate (BeamSearch -> ProdBatched ->
    # sgemm -> abort). We ship no BLAS, so route x86's float sgemm through ruy too
    # (portable; ruy has x86 AVX2/SSE kernels). int8 stays on intgemm. Requires
    # engine patch 0006 (marian builds ruy under USE_RUY_SGEMM, not only USE_RUY).
    if(NOT TRANSLATEKIT_ARCH_ARM)
        set(USE_RUY_SGEMM ON CACHE BOOL "" FORCE)
    endif()

    add_subdirectory(${engine_dir} ${CMAKE_BINARY_DIR}/bergamot EXCLUDE_FROM_ALL)

    # The bergamot wrapper and marian itself include marian's SIMD headers.
    _translatekit_apply_marian_arch_flags(marian)
    _translatekit_apply_marian_arch_flags(bergamot-translator-source)
endfunction()

function(translatekit_link_engine target engine_dir)
    target_link_libraries(${target} PRIVATE bergamot-translator-source)
    target_include_directories(${target} PRIVATE
            ${engine_dir}/src
            ${engine_dir}/marian-fork/src
            ${engine_dir}/marian-fork/src/3rd_party
            ${engine_dir}/3rd_party/ssplit-cpp/src)
    target_compile_definitions(${target} PRIVATE TRANSLATEKIT_WITH_ENGINE=1)
    # Our translator.cpp includes marian headers, so it needs the same arch flags.
    _translatekit_apply_marian_arch_flags(${target})
endfunction()
