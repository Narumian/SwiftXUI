// swift-tools-version: 6.0
// SwiftX — renderer-neutral shader, scene, and XView foundations.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftX",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "XShader", targets: ["XShader"]),
        .library(name: "XRender", targets: ["XRender"]),
        .library(name: "XUI", targets: ["XUI"]),
        .library(name: "XUISceneKit", targets: ["XUISceneKit"]),
        .library(name: "XUIHost", targets: ["XUIHost"]),
        .executable(name: "xview-bench", targets: ["xview-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0-latest"),
    ],
    targets: [
        .macro(
            name: "XUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "XShader",
            resources: [.process("Resources")]
        ),
        .target(
            name: "XRender",
            dependencies: ["XShader"]
        ),
        .target(
            name: "XUI",
            dependencies: [
                "XShader",
                "XUIMacros",
            ]
        ),
        .target(
            name: "XUISceneKit",
            dependencies: [
                "XUI",
                "XRender",
                "XShader",
            ]
        ),
        .target(
            name: "XUIHost",
            dependencies: [
                "XUI",
                "XRender",
                "XUISceneKit",
            ]
        ),
        .executableTarget(name: "xview-bench", dependencies: ["XUI"]),
        .testTarget(name: "XShaderTests", dependencies: ["XShader"]),
        .testTarget(name: "XRenderTests", dependencies: ["XRender", "XShader"]),
        .testTarget(name: "XUITests", dependencies: ["XUI"]),
        .testTarget(
            name: "XUIMacrosTests",
            dependencies: [
                "XUIMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "XUISceneKitTests",
            dependencies: ["XUISceneKit", "XRender", "XShader"]
        ),
        .testTarget(name: "XUIHostTests", dependencies: ["XUIHost", "XRender"]),
    ]
)
