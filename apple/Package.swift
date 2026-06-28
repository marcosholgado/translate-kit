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

// translate-kit for Apple platforms: on-device neural machine translation +
// offline language detection. A thin Swift API (`TranslateKit`) over the same
// platform-neutral C ABI the Android wrapper uses, layered on a prebuilt
// XCFramework that bundles the merged static engine per slice.
//
// The XCFramework is produced by scripts/build-apple.sh (gitignored build
// output). E.2 ships the macOS-arm64 slice; E.3 adds macOS-x86_64 (-> universal,
// for Intel Macs) and the iOS device/simulator slices to the same XCFramework,
// so this manifest does not change as platforms are added. For distribution as
// a remote dependency (E.5) the binaryTarget switches from `path:` to a
// `url:`+`checksum:` release artifact.
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
        .binaryTarget(
            name: "CTranslateKit",
            path: "build/TranslateKit.xcframework"
        ),
        // Public Swift API over the C ABI.
        .target(
            name: "TranslateKit",
            dependencies: ["CTranslateKit"],
            linkerSettings: [
                // System dependencies the merged static engine needs at final
                // link (derived from CMake's own link line; see build-apple.sh).
                .linkedLibrary("iconv"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "TranslateKitTests",
            dependencies: ["TranslateKit"]
        ),
    ]
)
