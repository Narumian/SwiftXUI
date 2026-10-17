# SwiftXUI

Renderer-neutral shaders, scene compilation, and an `XView` UI layer (SwiftUI-shaped API) for iOS and macOS.

## Requirements

- Swift 6.0+
- Xcode with Command Line Tools (for `xcodebuild` and Apple platform SDKs)

## Setup

`XRenderWGPU` links against a local **wgpu-native** binary that is not checked into git.

```bash
bash Scripts/fetch-wgpu.sh
```

This creates `Vendor/CWGPU.xcframework` (iOS device, iOS simulator, macOS arm64).

## Build and test

```bash
swift build
swift test
```

## Package products

| Product | Role |
|---------|------|
| `X` | Shared utilities and macros |
| `XShader` | WGSL shader assets and registry |
| `XRender` | Scene graph, draw commands, fonts (renderer-agnostic) |
| `XRenderWGPU` | WebGPU / wgpu-native backend |
| `XRenderApple` | Apple Metal surface helpers |
| `XUI` | `XView` layout, state, animation, FX, X3D authoring |
| `XUIHost` | App/runtime bridge to a renderer |
| `xview-bench` | Layout micro-benchmark executable |

## Third-party dependencies

- [swift-syntax](https://github.com/swiftlang/swift-syntax) (Apache-2.0) — resolved via Swift Package Manager
- [wgpu-native](https://github.com/gfx-rs/wgpu-native) — downloaded by `Scripts/fetch-wgpu.sh`; follow that project’s license if you redistribute the xcframework

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
