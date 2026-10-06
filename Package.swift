// swift-tools-version: 6.0
// SwiftX — renderer-neutral shader, scene, and XView foundations.

import CompilerPluginSupport
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

#if os(Linux)
let linuxArch: String = {
    #if arch(arm64)
    return "linux-aarch64"
    #else
    return "linux-x86_64"
    #endif
}()
let linuxWgpuRoot = packageDir.appendingPathComponent("Vendor/\(linuxArch)")
let linuxWgpuLib = linuxWgpuRoot.appendingPathComponent("lib").path

/// clang/ld.gold does not search g++'s private libdir for `-lstdc++`.
let linuxStdcxxLibDir: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/g++")
    process.arguments = ["-print-file-name=libstdc++.so"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && path != "libstdc++.so" {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
    } catch {}
    return "/usr/lib/gcc/x86_64-linux-gnu/13"
}()

let linuxWgpuLinker: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(linuxStdcxxLibDir)",
        // Link the static archive by path so we never pick up a same-named .so.
        "\(linuxWgpuLib)/libwgpu_native.a",
    ]),
    .linkedLibrary("stdc++"),
    .linkedLibrary("dl"),
    .linkedLibrary("m"),
    .linkedLibrary("pthread"),
    .linkedLibrary("vulkan"),
]
#endif

#if os(Linux)
let cwgpuTarget: Target = .systemLibrary(
    name: "CWGPU",
    path: "Vendor/\(linuxArch)"
)
let platformRenderProducts: [Product] = [
    .library(name: "XRenderLinux", targets: ["XRenderLinux"]),
]
let platformRenderTargets: [Target] = [
    .target(
        name: "XRenderLinux",
        dependencies: ["CWGPU"],
        path: "Sources/XRenderLinux",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("../../Vendor/\(linuxArch)/include"),
        ],
        linkerSettings: linuxWgpuLinker + [
            .linkedLibrary("X11"),
        ]
    ),
]
let xrenderWGPULinker: [LinkerSetting] = linuxWgpuLinker
#else
let cwgpuTarget: Target = .binaryTarget(
    name: "CWGPU",
    path: "Vendor/CWGPU.xcframework"
)
let platformRenderProducts: [Product] = [
    .library(name: "XRenderApple", targets: ["XRenderApple"]),
]
let platformRenderTargets: [Target] = [
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
let xrenderWGPULinker: [LinkerSetting] = [
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("IOSurface", .when(platforms: [.iOS])),
    .linkedLibrary("c++"),
]
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
        .library(name: "XRenderWGPU", targets: ["XRenderWGPU"]),
        .library(name: "XUI", targets: ["XUI"]),
        .library(name: "XUIHost", targets: ["XUIHost"]),
        .executable(name: "xview-bench", targets: ["xview-bench"]),
    ] + platformRenderProducts,
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0-latest"),
    ],
    targets: [
        cwgpuTarget,
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
            linkerSettings: xrenderWGPULinker
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
    ] + platformRenderTargets
)
