// swift-tools-version: 6.0
// SwiftX — renderer-neutral shader, scene, and XView foundations.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftX",
    products: [
        .library(name: "CWGPU", targets: ["CWGPU"]),
        .library(name: "X", targets: ["X"]),
        .library(name: "XShader", targets: ["XShader"]),
        .library(name: "XRender", targets: ["XRender"]),
        .library(name: "XRenderWGPU", targets: ["XRenderWGPU"]),
        .library(name: "XRenderApple", targets: ["XRenderApple"]),
        .library(name: "XCombine", targets: ["XCombine"]),
        .library(name: "XUI", targets: ["XUI"]),
        .library(name: "XUIHost", targets: ["XUIHost"]),
        .library(name: "XPreview", targets: ["XPreview"]),
        .library(name: "XDocument", targets: ["XDocument"]),
        .library(name: "XDocumentApple", targets: ["XDocumentApple"]),
        .library(name: "XWorkspace", targets: ["XWorkspace"]),
        .library(name: "XWorkspaceApple", targets: ["XWorkspaceApple"]),
        .library(name: "XWorkspaceUI", targets: ["XWorkspaceUI"]),
        .library(name: "XLive", targets: ["XLive"]),
        .library(name: "XLiveApple", targets: ["XLiveApple"]),
        .executable(name: "xview-bench", targets: ["xview-bench"]),
        .executable(name: "xbrowser-preview", targets: ["xbrowser-preview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Narumian/XLaser.git", revision: "2f1df50d5ebedfefe19d2a40e6c0cd1a19a049ed"),
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
        .target(name: "XCombine"),
        .target(
            name: "XUI",
            dependencies: [
                "X",
                "XCombine",
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
        .target(name: "XDocument"),
        .target(name: "XDocumentApple", dependencies: ["XDocument"]),
        .testTarget(name: "XDocumentTests", dependencies: ["XDocument"]),
        .target(name: "XWorkspace"),
        .target(name: "XWorkspaceApple", dependencies: ["XWorkspace"]),
        .target(name: "XWorkspaceUI", dependencies: ["XUI", "XWorkspace"]),
        .testTarget(name: "XWorkspaceUITests", dependencies: ["XWorkspaceUI", "XWorkspace", "XUI"]),
        .executableTarget(name: "xworkspace-bench", dependencies: ["XWorkspaceUI", "XWorkspace", "XWorkspaceApple", "XUI"]),
        .target(name: "XLive", dependencies: ["XUI", "XCombine", .product(name: "XLaser", package: "XLaser")],
                resources: [.process("Resources")]),
        .target(name: "XLiveApple", dependencies: ["XLive"]),
        .testTarget(name: "XLiveTests", dependencies: ["XLive", "XLiveApple", "XUI"]),
        .testTarget(name: "XWorkspaceTests", dependencies: ["XWorkspace"]),
        .testTarget(name: "XWorkspaceAppleTests", dependencies: ["XWorkspaceApple", "XWorkspace"]),
        .target(name: "XPreview", dependencies: ["XUI", "XUIHost", "XRender", "XRenderWGPU"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "xbrowser-preview", dependencies: ["XPreview", "XUI", "XUIHost", "XRender", "XWorkspace", "XWorkspaceUI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "XPreviewTests", dependencies: ["XPreview", "XUI", "XRender"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "xview-bench", dependencies: ["XUI"]),
        .executableTarget(name: "xcombine-bench", dependencies: ["XCombine"]),
        .executableTarget(name: "xlive-bench", dependencies: ["XLive", "XCombine"]),
        .testTarget(name: "XCombineTests", dependencies: ["XCombine"]),
        .testTarget(name: "XShaderTests", dependencies: ["XShader"]),
        .testTarget(name: "XRenderTests", dependencies: ["XRender", "XShader"]),
        .testTarget(name: "XRenderWGPUTests", dependencies: ["XRenderWGPU", "XRender", "XLive", "XUIHost"]),
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
