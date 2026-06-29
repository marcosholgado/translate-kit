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
#   E.1: macos-arm64 slice + merged archive + C-ABI smoke. <- DONE
#   E.3: macos-x86_64 -> universal macOS (Intel); ios-arm64 (device) +
#        iossim-{arm64,x86_64} -> universal ios-simulator; 3-platform
#        XCFramework (macos / ios / ios-simulator). <- DONE
#   E.4: optional slice allow-list (build a subset; the XCFramework is assembled
#        from whatever was built) so CI can build only what it tests. <- DONE
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
#   scripts/build-apple.sh                            # build ALL 5 slices + XCFramework
#   scripts/build-apple.sh macos-arm64 iossim-arm64   # build only these slices; the
#                                                     # XCFramework is assembled from
#                                                     # whatever was built (CI subset)
#   scripts/build-apple.sh --help
#
# Slices: macos-arm64 macos-x86_64 ios-arm64 iossim-arm64 iossim-x86_64
#
# Toolchain overrides (env): CMAKE_BIN, NINJA_BIN (default: the Android SDK copy,
# which is the cmake/ninja already proven on this host; on a CI runner without
# the Android SDK, point these at Homebrew's cmake/ninja).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMAKE_BIN="${CMAKE_BIN:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake}"
NINJA_BIN="${NINJA_BIN:-$HOME/Library/Android/sdk/cmake/3.22.1/bin/ninja}"

MACOS_DEPLOYMENT_TARGET="12.0"
IOS_DEPLOYMENT_TARGET="15.0"
MODEL_DIR="$REPO_ROOT/models/test-models/ende.student.tiny11"

ALL_SLICES=(macos-arm64 macos-x86_64 ios-arm64 iossim-arm64 iossim-x86_64)

usage() {
    cat <<'EOF'
Usage: scripts/build-apple.sh [SLICE ...]

Builds translate-kit for Apple platforms and assembles TranslateKit.xcframework.
With no args, builds all 5 slices. With an explicit allow-list, builds only those
slices and assembles the XCFramework from whatever was built (used by CI to build
only what it tests).

Slices:
  macos-arm64  macos-x86_64  ios-arm64  iossim-arm64  iossim-x86_64

Env overrides:
  CMAKE_BIN, NINJA_BIN   cmake/ninja to use (default: the Android SDK copy; on a
                         CI runner without it, point at Homebrew's cmake/ninja).
EOF
}

# Optional positional args = an allow-list of slices to build (default: all).
# A subset still produces a valid XCFramework, assembled from whatever was built.
REQUESTED_SLICES=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        macos-arm64|macos-x86_64|ios-arm64|iossim-arm64|iossim-x86_64)
            REQUESTED_SLICES+=("$arg") ;;
        *)
            echo "error: unknown slice '$arg' (valid: ${ALL_SLICES[*]})" >&2
            exit 1
            ;;
    esac
done
if [ "${#REQUESTED_SLICES[@]}" -eq 0 ]; then
    REQUESTED_SLICES=("${ALL_SLICES[@]}")
fi

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

    # Per-platform configure flags. The engine objects must be compiled for the
    # deployment floor and the right SDK/platform (not the build host's), else they
    # are stamped wrong and the consumer link warns/breaks. CMAKE_SYSTEM_NAME=iOS
    # puts CMake in cross-compile mode; the engine's TargetArch + PCRE2
    # ExternalProject pick the platform up via patches 0008/0009 (PCRE2 JIT is
    # forced off on iOS there). sdk_name + minos_flag are reused below to re-link
    # the standalone smoke against the right SDK.
    #
    # CMAKE_SYSTEM_PROCESSOR (iOS only): setting CMAKE_SYSTEM_NAME alone leaves
    # CMAKE_SYSTEM_PROCESSOR empty, and deps that gate source selection on it (ruy's
    # bundled cpuinfo) then drop their arm/x86 backend — e.g. cpuinfo skips
    # src/arm/mach/init.c and ruy fails to link (cpuinfo_arm_mach_init/cpuinfo_isa
    # undefined). Pin it to the slice's target arch (the standard cross-compile
    # practice). macOS slices are native (no CMAKE_SYSTEM_NAME) so it stays the host.
    #
    # CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY (iOS only): CMake's configure
    # checks (check_include_file, find_package(Threads), ...) default to building
    # an *executable*, whose link step fails when cross-compiling to iOS (`ld:
    # library 'System' not found`) — so e.g. pthread.h is wrongly reported missing
    # and sentencepiece's find_package(Threads) aborts configure. Building those
    # probes as static libs makes them compile-only (no link), the standard fix
    # for an unrunnable cross target. macOS slices link host executables fine and
    # don't need it.
    #
    # CMAKE_MACOSX_BUNDLE=OFF (iOS only): CMake defaults add_executable() to a
    # MACOSX_BUNDLE on iOS, so sentencepiece's `install(TARGETS spm_* RUNTIME ...)`
    # fails configure ("no BUNDLE DESTINATION"). We can't just drop those CLI tools
    # (marian set_property's them), so instead make iOS executables plain (non-
    # bundle): install() then validates. We only build the tk_smoke target, so the
    # CLI tools are configured but never compiled — zero cost, none in the archive.
    local cmake_platform_flags=()
    local minos_flag=""
    local sdk_name=""
    case "$slice" in
        macos-*)
            sdk_name="macosx"
            cmake_platform_flags+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET")
            minos_flag="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET"
            ;;
        ios-*)
            # iOS device (arm64). ruy + Accelerate ARM path.
            sdk_name="iphoneos"
            cmake_platform_flags+=(
                -DCMAKE_SYSTEM_NAME=iOS
                -DCMAKE_SYSTEM_PROCESSOR="$arch"
                -DCMAKE_OSX_SYSROOT=iphoneos
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
                -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
                -DCMAKE_MACOSX_BUNDLE=OFF)
            minos_flag="-mios-version-min=$IOS_DEPLOYMENT_TARGET"
            ;;
        iossim-*)
            # iOS simulator (arm64 + x86_64), runs on the host Mac's Simulator.
            sdk_name="iphonesimulator"
            cmake_platform_flags+=(
                -DCMAKE_SYSTEM_NAME=iOS
                -DCMAKE_SYSTEM_PROCESSOR="$arch"
                -DCMAKE_OSX_SYSROOT=iphonesimulator
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
                -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
                -DCMAKE_MACOSX_BUNDLE=OFF)
            minos_flag="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
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
    # alone (no CMake target graph), the way an XCFramework consumer links. The
    # SDK must be pinned per slice — without -isysroot, clang defaults to the macOS
    # SDK and an iOS slice would link against the wrong frameworks.
    echo "==> [$slice] re-link smoke against the merged archive only"
    local sdk_path; sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
    local sdk_flags=(-arch "$arch" -isysroot "$sdk_path" "$minos_flag")
    xcrun clang "${sdk_flags[@]}" -I "$REPO_ROOT/core/include" \
        -c "$REPO_ROOT/apple/smoke/smoke.c" -o "$build_dir/smoke_standalone.o"
    xcrun clang++ "${sdk_flags[@]}" \
        "$build_dir/smoke_standalone.o" "$merged" "${syslibs[@]}" \
        -o "$build_dir/tk_smoke_standalone"

    # Run the smoke only on a NATIVE macOS slice matching the build host's arch.
    # Cross-compiled slices (an x86_64 slice on this arm64 host, and every iOS
    # slice) are link-only: building tk_smoke and re-linking tk_smoke_standalone
    # above already proved the merged archive is symbol-complete, which is what the
    # smoke verifies. Functional iOS coverage is a later `xcodebuild test` on a
    # simulator; functional x86_64 coverage is a CI job on an Intel runner.
    if [ "$slice" = "macos-$(uname -m)" ]; then
        # CMake-linked first (target-graph proof), then the merged-archive build
        # (packaging proof). With a test model present they also assert a live
        # en->de translation; otherwise they still exercise the full link.
        # Optional `env TK_TEST_MODEL_DIR=...` prefix when a test model is present
        # (then the smoke also asserts a live translation). The `[@]+...` guard
        # makes the EMPTY-array case safe under `set -u` on bash 3.2 (macOS's
        # default /bin/bash), where a bare "${model_env[@]}" aborts with
        # "unbound variable" — which is exactly the model-less release build.
        local model_env=()
        if [ -d "$MODEL_DIR" ]; then
            model_env=(env "TK_TEST_MODEL_DIR=$MODEL_DIR")
        else
            echo "    note: $MODEL_DIR absent (run scripts/fetch-models.sh); smoke runs without live translation"
        fi

        echo "==> [$slice] run tk_smoke (CMake-linked)"
        "${model_env[@]+"${model_env[@]}"}" "$build_dir/tk_smoke"
        echo "==> [$slice] run tk_smoke_standalone (merged-archive-linked)"
        "${model_env[@]+"${model_env[@]}"}" "$build_dir/tk_smoke_standalone"
    else
        echo "==> [$slice] link-only (cross-compiled, not host-runnable); tk_smoke + standalone linked OK"
    fi

    echo "==> [$slice] OK"
}

# stage_headers <dir>
# Stages the C ABI header + clang module map into <dir>, the layout the
# XCFramework copies into each slice's Headers/ so Swift can `import CTranslateKit`.
stage_headers() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/translate_kit"
    cp "$REPO_ROOT/core/include/translate_kit/translate_kit.h" "$dir/translate_kit/"
    cp "$REPO_ROOT/apple/cmodule/module.modulemap" "$dir/module.modulemap"
}

# Build each requested slice. The arch is the trailing token of the slice name
# (macos-arm64 -> arm64, iossim-x86_64 -> x86_64); build_slice keys the platform
# off the leading token.
for slice in "${REQUESTED_SLICES[@]}"; do
    build_slice "$slice" "${slice##*-}"
done

# An XCFramework holds at most ONE library per platform, so same-platform arches
# must be fused into a single fat (universal) archive — separate -library entries
# for one platform are rejected. macOS arm64+x86_64 → one `macos` library;
# iossim arm64+x86_64 → one `ios-simulator` library; the iOS device slice is its
# own platform (a single arm64 archive). That yields the (up to) 3 distinct
# platforms an XCFramework needs: macos / ios / ios-simulator.
lipo_universal() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    rm -f "$out"
    echo "==> lipo $(basename "$(dirname "$out")") <- $*"
    lipo -create "$@" -output "$out"
    lipo -info "$out" | sed 's/^/    /'
}

LIB_ROOT="$REPO_ROOT/apple/build/lib"
HEADERS_STAGE="$REPO_ROOT/apple/build/headers"
XCFRAMEWORK="$REPO_ROOT/apple/build/TranslateKit.xcframework"
stage_headers "$HEADERS_STAGE"

# add_platform <fused-out.a> <slice> [<slice> ...]
# Fuses whichever of the named slices were built THIS run into one library (lipo
# copies a lone arch, fuses several) and queues it as an XCFramework -library
# with the staged C-ABI headers. Skips the platform when none of its slices were
# requested — so a CI subset assembles a smaller-but-valid XCFramework. Gated on
# REQUESTED_SLICES (not just archive existence) so a stale archive left by a
# previous full build is never silently folded into a subset build.
XCF_ARGS=()
add_platform() {
    local out="$1"; shift
    local inputs=() s
    for s in "$@"; do
        case " ${REQUESTED_SLICES[*]} " in *" $s "*) ;; *) continue ;; esac
        [ -f "$LIB_ROOT/$s/libtranslatekit.a" ] && inputs+=("$LIB_ROOT/$s/libtranslatekit.a")
    done
    [ "${#inputs[@]}" -eq 0 ] && return 0
    lipo_universal "$out" "${inputs[@]}"
    XCF_ARGS+=(-library "$out" -headers "$HEADERS_STAGE")
}

add_platform "$LIB_ROOT/macos/libtranslatekit.a"        macos-arm64 macos-x86_64
add_platform "$LIB_ROOT/ios-device/libtranslatekit.a"   ios-arm64
add_platform "$LIB_ROOT/iossimulator/libtranslatekit.a" iossim-arm64 iossim-x86_64

if [ "${#XCF_ARGS[@]}" -eq 0 ]; then
    echo "error: no slices were built; nothing to assemble" >&2
    exit 1
fi

echo "==> assemble TranslateKit.xcframework"
rm -rf "$XCFRAMEWORK"
xcrun xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$XCFRAMEWORK"

echo
echo "Apple slices built and verified (${REQUESTED_SLICES[*]}); XCFramework assembled:"
echo "  $XCFRAMEWORK"
echo "  platforms: $(ls "$XCFRAMEWORK" | grep -v Info.plist | tr '\n' ' ')"
echo
# The root Package.swift defaults to the remote release XCFramework; set
# TRANSLATEKIT_LOCAL_XCFRAMEWORK=1 to test against the slice just built here.
echo "Run the Swift goldens (macOS host):"
echo "  TRANSLATEKIT_LOCAL_XCFRAMEWORK=1 TK_TEST_MODEL_DIR=\"$MODEL_DIR\" \\"
echo "    swift test --package-path \"$REPO_ROOT\""
echo "Run the iOS-simulator goldens (boot a sim, inject the model dir, then test):"
echo "  SIM=<booted-arm64-sim-udid>"
echo "  xcrun simctl spawn \"\$SIM\" launchctl setenv TK_TEST_MODEL_DIR \"$MODEL_DIR\""
echo "  ( cd \"$REPO_ROOT\" && TRANSLATEKIT_LOCAL_XCFRAMEWORK=1 xcodebuild test \\"
echo "      -scheme TranslateKit -destination \"platform=iOS Simulator,id=\$SIM\" )"
