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

# Host (developer-machine) gtest suite for the C ABI. Fetches GoogleTest.

include(FetchContent)
FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG v1.15.2
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(translatekit_core_test c_api_test.cpp)
target_link_libraries(translatekit_core_test PRIVATE translatekit_core GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(translatekit_core_test)

# Manual dev tool for interactive language-detection testing (not shipped).
add_executable(detect_cli detect_cli.cpp)
target_link_libraries(detect_cli PRIVATE translatekit_core)
