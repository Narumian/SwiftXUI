# SwiftXUI

Renderer-neutral shaders, scene compilation, and an `XView` UI layer (SwiftUI-shaped API).

## Requirements

- Swift 6.0+
- Apple builds require Xcode and the corresponding SDK. `X.Group`, the
  composable builder's array support, and the LaserCube driver require
  macOS 13, iOS 16, tvOS 16, or watchOS 9 for their Swift runtime APIs.
- `XRenderApple` and the bundled `CWGPU.xcframework` are Apple-specific.
  Other platforms need a compatible rendering backend; not all products have
  been verified on every platform.

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
