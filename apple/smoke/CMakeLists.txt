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

# Apple C-ABI smoke harness. Pulls in the platform-agnostic core (../../core)
# with the Bergamot engine and links a tiny C executable against it, the same way
# android/translate-kit/CMakeLists.txt wraps the core with its JNI shim. Building
# the `tk_smoke` target here proves the CMake target graph links for an Apple
# slice; scripts/build-apple.sh then re-links the same source against the merged
# static archive to prove that shippable artifact is symbol-complete.
#
# Configure with -DTRANSLATEKIT_WITH_ENGINE=ON (and the per-slice CMAKE_OSX_*
# flags); the engine is what makes this a meaningful link test.

cmake_minimum_required(VERSION 3.18.1)

project(translatekit_apple_smoke LANGUAGES C CXX)

# Build the shared core (static lib) from the repo root. An explicit binary dir
# is required because the source lives outside this directory tree.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../core ${CMAKE_CURRENT_BINARY_DIR}/translatekit_core)

add_executable(tk_smoke smoke.c)
target_link_libraries(tk_smoke PRIVATE translatekit_core)
