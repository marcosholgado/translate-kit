// swift-tools-version: 5.9
//
// Copyright 2026 Marcos Holgado
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import PackageDescription
import Foundation

// translate-kit for Apple platforms: on-device neural machine translation +
// offline language detection. A thin Swift API (`TranslateKit`) over the same
// platform-neutral C ABI the Android wrapper uses, layered on a prebuilt
// XCFramework that bundles the merged static engine per slice.
//
// This manifest lives at the repo ROOT (not under apple/) so the package resolves
// as a remote SwiftPM dependency by Git URL + version: a consuming app adds
// `https://github.com/marcosholgado/translate-kit` and SwiftPM downloads the
// prebuilt XCFramework from the matching GitHub Release — no need to clone this
// repo or build the C++ engine. The Swift sources and tests stay under apple/ and
// are referenced here via explicit `path:`.
//
// Binary distribution: by default `CTranslateKit` is the prebuilt XCFramework from
// the matching release (the `url:`/`checksum:` below are maintained per release by
// .github/workflows/release.yml). For local development against a freshly-built
// XCFramework — `scripts/build-apple.sh` then `swift test` — set the env var
// TRANSLATEKIT_LOCAL_XCFRAMEWORK=1 to resolve apple/build/TranslateKit.xcframework
// instead. (Until the first release is published, that env var is also how a
// fresh checkout of `main` resolves, since the remote artifact does not yet exist.)
let useLocalXCFramework = ProcessInfo.processInfo.environment["TRANSLATEKIT_LOCAL_XCFRAMEWORK"] != nil

let binaryTarget: Target = useLocalXCFramework
    ? .binaryTarget(
        name: "CTranslateKit",
        path: "apple/build/TranslateKit.xcframework")
    : .binaryTarget(
        name: "CTranslateKit",
        // RELEASE-MANAGED: the version in this URL and the checksum are rewritten
        // by .github/workflows/release.yml for each release; do not hand-edit.
        url: "https://github.com/marcosholgado/translate-kit/releases/download/v0.1.0/TranslateKit.xcframework.zip",
        checksum: "0000000000000000000000000000000000000000000000000000000000000000")

let package = Package(
    name: "TranslateKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "TranslateKit", targets: ["TranslateKit"]),
    ],
    targets: [
        // Prebuilt engine + C ABI (CTranslateKit clang module), per-slice.
        binaryTarget,
        // Public Swift API over the C ABI.
        .target(
            name: "TranslateKit",
            dependencies: ["CTranslateKit"],
            path: "apple/Sources/TranslateKit",
            linkerSettings: [
                // System dependencies the merged static engine needs at final
                // link (derived from CMake's own link line; see build-apple.sh).
                // These propagate to a consuming app that links TranslateKit.
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "TranslateKitTests",
            dependencies: ["TranslateKit"],
            path: "apple/Tests/TranslateKitTests"
        ),
    ]
)
