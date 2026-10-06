# X3D authoring guide

SwiftX keeps a **thin GPU DSL** (`Buffer` / `Draw` / `Pass` / `Compute` / …).
High-level helpers exist for the 80% cases; they still lower 1:1 into those primitives.

## Sugar

| Helper | Use when |
|---|---|
| `MeshDraw(shader, mesh:)` | Drawing `X3DMesh` / interleaved pos+normal floats |
| `MeshDraw(...).instanced(transforms:)` | Many copies of the same mesh (preferred over bare `Instanced` for meshes) |
| `Instanced(shader, transforms:, vertices:)` | Vertex-index / sprite geometry without a mesh buffer |
| `Fullscreen(shader)` | Three-vertex fullscreen triangle |
| `FeedbackTrail("trail") { … }` | Fade-load offscreen pass + blit (particle trails) |
| `Camera(..., acceptsInput: true)` | Interactive 2D-in-3D panels (precise ray-plane pick via `X3DPlaneHit`, including tilted models) |

`Buffer(_:transforms:)` was already on main — instanced matrix upload is not new; the sugar is composing mesh + instances + draw.

## Diagnostics

After `LayoutHost` / `XUIHost.render`, check `RenderResult.x3dDiagnostics`:

- Undeclared bindings / pass targets / blits (always)
- Unregistered `ShaderKey`s when `environment.x3dRegisteredShaders` is set

```swift
var env = EnvironmentValues()
env.x3dRegisteredShaders = ["flow", "lit"]
let host = LayoutHost(canvas: size, environment: env)
let result = await host.render(root, into: canvas)
for issue in result.x3dDiagnostics { print(issue) }
```

WGPU DEBUG builds **log** the same issues at encode time; they no longer hard-assert (use `X3DDiagnostics.assertValid` in tests if you want that).

## Time sync

`X3DTimeSync` / `XAppDriver.timeSync`: pass the same display-link timestamp into FX (`fxTime`, absolute) and the renderer (`x3d.time`, epoch-relative).

## Plane resolution & buffer reupload

See contracts encoded by `X3DPlanePolicy` and `X3DBufferUploadPolicy`:

- Plane world size = layout points / 100; offscreen target = full framebuffer; UV letterboxes content
- Buffer reuse when `byteCount` matches and either `generation` matches (preferred) or `contents` are equal
- Same-size content/generation change → in-place rewrite (`writeBuffer`); size change → recreate
- Author tip: pass `Buffer(_:contents:generation:)` and bump the token when data changes to skip O(n) compares

```swift
Buffer("particles", contents: floats, generation: frameIndex)
```

## Cost probe

```swift
X3DCostProbe.shared.isEnabled = true
X3DCostProbe.shared.beginFrame()
// … render / encode …
X3DCostProbe.shared.endFrame()
let sample = X3DCostProbe.shared.last  // walk / assemble / encode ns + metrics + churn
```

`XAppDriver.frame(at:)` wraps begin/end automatically.
