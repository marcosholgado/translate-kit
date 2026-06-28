#!/usr/bin/env bash
#
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
#
# Builds translate-kit for Apple platforms.
#
# Per the engine's architecture gate (core/cmake/BergamotEngine.cmake keys SIMD/
# GEMM off the single target ARCHITECTURE), each arch/platform must be built as a
# SEPARATE slice — a universal single compile would defeat that gate. Each slice
# is compiled, then ALL of its transitive static archives (translatekit_core +
# cld2 + the Bergamot engine: marian, sentencepiece, ssplit, ruy, pcre2, ...) are
# merged into one self-contained libtranslatekit.a — the unit an XCFramework
# ships per slice. The merged archive is then verified by re-linking the C-ABI
# smoke (apple/smoke) against it alone, proving it is symbol-complete.
#
# Subphase status:
#   E.1 (this commit): macos-arm64 slice + merged archive + C-ABI smoke. <- DONE
#   E.3 (later):       macos-x86_64, ios-arm64, iossim-{arm64,x86_64}; lipo +
#                      `xcodebuild -create-xcframework`.
#
# Prerequisites (one-time, see README):
#   git submodule update --init --recursive third_party/cld2
#   git submodule update --init third_party/translations
#   git -C third_party/translations submodule update --init --recursive \
#     inference/3rd_party/ssplit-cpp \
#     inference/marian-fork/src/3rd_party/{sentencepiece,intgemm,ruy,simd_utils}
#   scripts/apply-engine-patches.sh
#
# Usage:
#   scripts/build-apple.sh                 # build + verify the macos-arm64 slice
#
# Toolchain overrides (env): CMAKE_BIN, NINJA_BIN (default: the Android SDK copy,
# which is the cmake/ninja already proven on this host).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMAKE_BIN="${CMAKE_BIN:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
NINJA_BIN="${NINJA_BIN:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/ninja}"

MACOS_DEPLOYMENT_TARGET="12.0"
MODEL_DIR="$REPO_ROOT/models/test-models/ende.student.tiny11"

for tool in "$CMAKE_BIN" "$NINJA_BIN"; do
    if [ ! -x "$tool" ]; then
        echo "error: not found/executable: $tool" >&2
        echo "  set CMAKE_BIN / NINJA_BIN to a cmake/ninja that supports Apple targets." >&2
        exit 1
    fi
done

if [ ! -f "$REPO_ROOT/third_party/translations/inference/CMakeLists.txt" ]; then
    echo "error: Bergamot engine submodule not initialized." >&2
    echo "  see the prerequisites in the header of this script." >&2
    exit 1
fi

# build_slice <slice-name> <arch> [extra cmake args...]
#
# Configures + builds the tk_smoke target for one slice, then merges every static
# archive CMake linked into apple/build/lib/<slice>/libtranslatekit.a and records
# the system libs/frameworks the engine needs (parsed from CMake's own link line,
# so it stays correct if the engine's dependency set changes).
build_slice() {
    local slice="$1"; shift
    local arch="$1"; shift

    local build_dir="$REPO_ROOT/apple/build/$slice"
    local lib_dir="$REPO_ROOT/apple/build/lib/$slice"
    local merged="$lib_dir/libtranslatekit.a"
    mkdir -p "$lib_dir"

    # Per-platform deployment-target flags. The engine objects must be compiled
    # for the deployment floor (not the build host's SDK), else they are stamped
    # with the host OS version and the consumer link warns/breaks. iOS slices add
    # CMAKE_SYSTEM_NAME / CMAKE_OSX_SYSROOT here in E.3.
    local cmake_platform_flags=()
    local minos_flag=""
    case "$slice" in
        macos-*)
            cmake_platform_flags+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET")
            minos_flag="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
            ;;
        *)
            echo "error: unknown slice '$slice'" >&2
            exit 1
            ;;
    esac

    echo "==> [$slice] configure"
    "$CMAKE_BIN" -S "$REPO_ROOT/apple/smoke" -B "$build_dir" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DTRANSLATEKIT_WITH_ENGINE=ON \
        "${cmake_platform_flags[@]}"

    echo "==> [$slice] build tk_smoke"
    "$CMAKE_BIN" --build "$build_dir" --target tk_smoke -j8

    # Parse CMake's link line for tk_smoke: collect the static archives (to merge)
    # and the system libs/frameworks (to re-link against the merged archive and,
    # later, to declare in the SwiftPM target's linkerSettings).
    local archives=()
    local syslibs=()
    local expect_framework=0
    local tok
    while IFS= read -r tok; do
        case "$tok" in
            *.a)
                case "$tok" in
                    /*) archives+=("$tok") ;;
                    *)  archives+=("$build_dir/$tok") ;;
                esac
                ;;
            -l*) syslibs+=("$tok") ;;
            -framework) expect_framework=1 ;;
            *)
                if [ "$expect_framework" -eq 1 ]; then
                    syslibs+=("-framework" "$tok")
                    expect_framework=0
                fi
                ;;
        esac
    done < <("$NINJA_BIN" -C "$build_dir" -t commands tk_smoke | tail -n1 | tr ' ' '\n')

    if [ "${#archives[@]}" -eq 0 ]; then
        echo "error: [$slice] no static archives found in tk_smoke link line" >&2
        exit 1
    fi

    echo "==> [$slice] merge ${#archives[@]} archives -> $merged"
    rm -f "$merged"
    xcrun libtool -static -o "$merged" "${archives[@]}"

    echo "    system link deps: ${syslibs[*]}"
    echo "    merged archive:"
    lipo -info "$merged" 2>/dev/null | sed 's/^/      /' || true
    du -h "$merged" | awk '{print "      size: " $1}'

    # Verify the MERGED archive is symbol-complete: re-link the smoke against it
    # alone (no CMake target graph), the way an XCFramework consumer links.
    echo "==> [$slice] re-link smoke against the merged archive only"
    local sdk_flags=(-arch "$arch" "$minos_flag")
    xcrun clang "${sdk_flags[@]}" -I "$REPO_ROOT/core/include" \
        -c "$REPO_ROOT/apple/smoke/smoke.c" -o "$build_dir/smoke_standalone.o"
    xcrun clang++ "${sdk_flags[@]}" \
        "$build_dir/smoke_standalone.o" "$merged" "${syslibs[@]}" \
        -o "$build_dir/tk_smoke_standalone"

    # Run both: CMake-linked first (target-graph proof), then the merged-archive
    # build (packaging proof). With a test model present they also assert a live
    # en->de translation; otherwise they still exercise the full link.
    local model_env=()
    if [ -d "$MODEL_DIR" ]; then
        model_env=(env "TK_TEST_MODEL_DIR=$MODEL_DIR")
    else
        echo "    note: $MODEL_DIR absent (run scripts/fetch-models.sh); smoke runs without live translation"
    fi

    echo "==> [$slice] run tk_smoke (CMake-linked)"
    "${model_env[@]}" "$build_dir/tk_smoke"
    echo "==> [$slice] run tk_smoke_standalone (merged-archive-linked)"
    "${model_env[@]}" "$build_dir/tk_smoke_standalone"

    echo "==> [$slice] OK"
}

build_slice "macos-arm64" "arm64"

echo
echo "macos-arm64 slice built and verified:"
echo "  $REPO_ROOT/apple/build/lib/macos-arm64/libtranslatekit.a"
