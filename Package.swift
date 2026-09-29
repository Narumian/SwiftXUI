// swift-tools-version: 6.0
// SwiftXUI — SwiftUI の手触りを持つ、コンパイル時静的なレイアウト DSL。
// コア(`SwiftXUI`)はSwiftXShaderのrenderer-neutral契約だけを参照し、
// `SwiftXUISceneKit` がGameRenderに橋を架ける。

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftXUI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwiftXUI", targets: ["SwiftXUI"]),
        .library(name: "SwiftXUISceneKit", targets: ["SwiftXUISceneKit"]),
        .executable(name: "xview-bench", targets: ["xview-bench"]),
    ],
    dependencies: [
        .package(path: "../GameRender"),
        .package(path: "../SwiftXShader"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0-latest"),
    ],
    targets: [
        .macro(
            name: "SwiftXUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftXUI",
            dependencies: [
                .product(name: "SwiftXShader", package: "SwiftXShader"),
                "SwiftXUIMacros",
            ]
        ),
        .target(
            name: "SwiftXUISceneKit",
            dependencies: [
                "SwiftXUI",
                .product(name: "GameRender", package: "GameRender"),
            ]
        ),
        // Measures the automatic-identity mechanism's real per-frame cost
        // (TaskLocal push, StateIdentity combine, whole-tree lower()) before
        // deciding whether the existential-avoiding walk redesign is worth it.
        .executableTarget(name: "xview-bench", dependencies: ["SwiftXUI"]),
        .testTarget(name: "SwiftXUITests", dependencies: ["SwiftXUI"]),
        // Tests macro diagnostics directly (e.g. @XState without @Stateful)
        // via assertMacroExpansion — no compile step needed, so a would-be
        // compile error can be asserted without breaking this test target's
        // own build.
        .testTarget(
            name: "SwiftXUIMacrosTests",
            dependencies: [
                "SwiftXUIMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SwiftXUISceneKitTests",
            dependencies: [
                "SwiftXUISceneKit",
                .product(name: "GameRender", package: "GameRender"),
            ]
        ),
    ]
)
