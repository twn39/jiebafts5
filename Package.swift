// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "jiebafts5",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "JiebaFTS5",
            targets: ["JiebaFTS5"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            .upToNextMajor(from: "7.5.0")
        ),
    ],
    targets: [
        // C++ glue layer: exposes cppjieba via a pure C API.
        // A C (not C++) interface keeps Swift targets free of
        // .interoperabilityMode(.Cxx), which would otherwise propagate to
        // GRDB and other dependencies.
        .target(
            name: "CJiebaWrapper",
            path: "Sources/CJiebaWrapper",
            publicHeadersPath: "include",
            cxxSettings: [
                // cppjieba is header-only under include/cppjieba/*.hpp
                // (vendored from upstream; limonp was removed in favor of
                // cppjieba/Utils.hpp). Path is relative to Sources/CJiebaWrapper/
                // and stays inside the package root for SPM.
                .headerSearchPath("../../include"),
            ]
        ),
        // Swift FTS5 custom tokenizer.
        .target(
            name: "JiebaFTS5",
            dependencies: [
                "CJiebaWrapper",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/JiebaFTS5",
            resources: [
                // Dictionary files must be bundled so Bundle.module can
                // resolve them at runtime on iOS / macOS.
                .copy("Resources/jieba.dict.utf8"),
                .copy("Resources/hmm_model.utf8"),
                .copy("Resources/user.dict.utf8"),
            ]
        ),
        .testTarget(
            name: "JiebaFTS5Tests",
            dependencies: [
                "JiebaFTS5",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/JiebaFTS5Tests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
