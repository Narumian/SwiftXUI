// swift-tools-version: 6.0
// SwiftX — renderer-neutral shader, scene, and XView foundations.

import CompilerPluginSupport
import PackageDescription

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let appleGPUProducts: [Product] = [
    .library(name: "XRenderWGPU", targets: ["XRenderWGPU"]),
    .library(name: "XRenderApple", targets: ["XRenderApple"]),
]
let appleGPUTargets: [Target] = [
    .binaryTarget(
        name: "CWGPU",
        path: "Vendor/CWGPU.xcframework"
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
        name: "XRenderApple",
        dependencies: ["CWGPU"],
        path: "Sources/XRenderApple",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedFramework("Metal"),
            .linkedFramework("QuartzCore"),
            .linkedFramework("IOSurface", .when(platforms: [.iOS])),
            .linkedLibrary("c++"),
        ]
    ),
]
#else
// Linux / non-Apple hosts: CWGPU.xcframework + Metal linker flags are unavailable.
let appleGPUProducts: [Product] = []
let appleGPUTargets: [Target] = []
#endif

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let appleUITestTargets: [Target] = [
    .testTarget(name: "XUITests", dependencies: ["XUI"]),
]
#else
// Linux Swift 6 rejects mutable captures in several XUITests view builders.
let appleUITestTargets: [Target] = []
#endif

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
    ] + appleGPUProducts + [
        .library(name: "XUI", targets: ["XUI"]),
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
    ] + appleGPUTargets + [
        .target(
            name: "XUI",
            dependencies: [
                "X",
                "XShader",
                "XRender",
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
        // XTests (AnyCodable/Aox) omitted: Aox runtime types are not in Sources/X yet.
        .testTarget(name: "XRenderTests", dependencies: ["XRender", "XShader"]),
    ] + appleUITestTargets + [
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
