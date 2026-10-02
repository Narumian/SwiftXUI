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
        .library(name: "X", targets: ["X"]),
        .library(name: "XShader", targets: ["XShader"]),
        .library(name: "XRender", targets: ["XRender"]),
        .library(name: "XRenderWGPU", targets: ["XRenderWGPU"]),
        .library(name: "XUI", targets: ["XUI"]),
        .library(name: "XUIHost", targets: ["XUIHost"]),
        .executable(name: "xview-bench", targets: ["xview-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0-latest"),
    ],
    targets: [
        .binaryTarget(
            name: "CWGPU",
            path: "Vendor/CWGPU.xcframework"
        ),
        .macro(
            name: "XUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .macro(
            name: "XMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "X",
            dependencies: ["XMacros"]
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
            name: "XRenderWGPU",
            dependencies: [
                "XRender",
                "XShader",
                "CWGPU",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface", .when(platforms: [.iOS])),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "XUI",
            dependencies: [
                "X",
                "XShader",
                "XUIMacros",
            ]
        ),
        .target(
            name: "XUIHost",
            dependencies: [
                "XUI",
                "XRender",
                "XShader",
            ]
        ),
        .executableTarget(name: "xview-bench", dependencies: ["XUI"]),
        .testTarget(name: "XShaderTests", dependencies: ["XShader"]),
        .testTarget(name: "XTests", dependencies: ["X"]),
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
            name: "XUIHostTests",
            dependencies: ["XUIHost", "XUI", "XRender", "XShader"]
        ),
    ]
)
