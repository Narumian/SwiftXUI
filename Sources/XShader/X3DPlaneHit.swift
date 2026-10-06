import Foundation

/// Picking for X3D panels that live on the model-space `z = 0` plane
/// (cards / sheets, including tilted / rotated models). World size matches
/// the encoder: `planeSize / 100` units across (`half-extents = planeSize / 200`).
///
/// Hits use a world-space ray against the transformed plane so heavily tilted
/// panels stay precise — not an axis-aligned screen box.
public enum X3DPlaneHit {
    public static let pointsPerWorldUnit: Float = 100

    /// Maps a point in the hosting `X3DView` (origin top-left, y down) onto the
    /// plane's layout coordinates (same convention) when the ray hits the panel.
    public static func hit(
        screen: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        planeSize: SIMD2<Float>,
        camera: X3DCamera,
        model: X3DTransform,
        time: Float = 0
    ) -> SIMD2<Float>? {
        guard viewSize.x > 0, viewSize.y > 0, planeSize.x > 0, planeSize.y > 0 else { return nil }
        let aspect = viewSize.x / viewSize.y
        let vp = camera.viewProjection(aspect: aspect, time: time)
        guard let invVP = invert(vp) else { return nil }

        let ndc = SIMD2(
            screen.x / viewSize.x * 2 - 1,
            1 - screen.y / viewSize.y * 2
        )
        let near = unproject(invVP, ndc: ndc, clipZ: 0)
        let far = unproject(invVP, ndc: ndc, clipZ: 1)
        let dir = far - near
        let dirLen2 = dot3(dir, dir)
        guard dirLen2 > 1e-12 else { return nil }

        // Panel lies on model z = 0. Transform that plane into world space.
        let m = model.matrix
        let origin = SIMD3(m[12], m[13], m[14])
        let axisX = SIMD3(m[0], m[1], m[2])
        let axisY = SIMD3(m[4], m[5], m[6])
        var normal = cross3(axisX, axisY)
        let normalLen2 = dot3(normal, normal)
        guard normalLen2 > 1e-12 else { return nil }
        normal /= normalLen2.squareRoot()

        let denom = dot3(normal, dir)
        guard abs(denom) > 1e-6 else { return nil } // edge-on / parallel
        let t = dot3(normal, origin - near) / denom
        guard t >= 0, t <= 1 else { return nil }
        let world = near + dir * t

        // World → model (affine inverse of the upper 3×3 + translation).
        guard let invModel = invert(m) else { return nil }
        let local4 = mul4(invModel, SIMD4(world.x, world.y, world.z, 1))
        let w = max(abs(local4.w), 1e-6) * (local4.w < 0 ? -1 : 1)
        let local = SIMD3(local4.x / w, local4.y / w, local4.z / w)
        guard abs(local.z) <= 1e-3 else { return nil }

        let half = planeSize / (2 * pointsPerWorldUnit)
        guard abs(local.x) <= half.x + 1e-5, abs(local.y) <= half.y + 1e-5 else { return nil }

        return SIMD2(
            (local.x / half.x * 0.5 + 0.5) * planeSize.x,
            (0.5 - local.y / half.y * 0.5) * planeSize.y
        )
    }

    /// `true` when the screen point lands on the panel (precise ray-plane hit).
    public static func contains(
        screen: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        planeSize: SIMD2<Float>,
        camera: X3DCamera,
        model: X3DTransform,
        time: Float = 0
    ) -> Bool {
        hit(
            screen: screen, viewSize: viewSize, planeSize: planeSize,
            camera: camera, model: model, time: time
        ) != nil
    }

    /// Maps a plane-local layout point (origin top-left, y down) into the
    /// hosting `X3DView` (same convention). Returns `nil` when the point is
    /// behind the camera or outside the clip volume.
    public static func project(
        local: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        planeSize: SIMD2<Float>,
        camera: X3DCamera,
        model: X3DTransform,
        time: Float = 0
    ) -> SIMD2<Float>? {
        guard viewSize.x > 0, viewSize.y > 0, planeSize.x > 0, planeSize.y > 0 else { return nil }
        let half = planeSize / (2 * pointsPerWorldUnit)
        let modelPoint = SIMD3(
            (local.x / planeSize.x * 2 - 1) * half.x,
            (1 - local.y / planeSize.y * 2) * half.y,
            0
        )
        let aspect = viewSize.x / viewSize.y
        let vp = camera.viewProjection(aspect: aspect, time: time)
        let mvp = multiply(vp, model.matrix)
        let clip = mul4(mvp, SIMD4(modelPoint.x, modelPoint.y, modelPoint.z, 1))
        guard clip.w > 1e-6 else { return nil }
        let ndc = SIMD2(clip.x / clip.w, clip.y / clip.w)
        return SIMD2(
            (ndc.x * 0.5 + 0.5) * viewSize.x,
            (0.5 - ndc.y * 0.5) * viewSize.y
        )
    }

    /// Screen-space axis-aligned bounds of a plane-local layout rect.
    /// Broad-phase only — use `hit` / `contains` for precise tilted picking.
    public static func projectRect(
        _ rect: (min: SIMD2<Float>, max: SIMD2<Float>),
        viewSize: SIMD2<Float>,
        planeSize: SIMD2<Float>,
        camera: X3DCamera,
        model: X3DTransform,
        time: Float = 0
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        let corners = [
            SIMD2(rect.min.x, rect.min.y), SIMD2(rect.max.x, rect.min.y),
            SIMD2(rect.max.x, rect.max.y), SIMD2(rect.min.x, rect.max.y),
        ]
        var minS = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maxS = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var visible = false
        for corner in corners {
            guard let screen = project(
                local: corner, viewSize: viewSize, planeSize: planeSize,
                camera: camera, model: model, time: time
            ) else { continue }
            minS = SIMD2(min(minS.x, screen.x), min(minS.y, screen.y))
            maxS = SIMD2(max(maxS.x, screen.x), max(maxS.y, screen.y))
            visible = true
        }
        return visible ? (minS, maxS) : nil
    }

    /// Screen-space axis-aligned bounds of the panel inside the hosting view.
    /// Useful for broad-phase hit tests; may be empty when the panel is edge-on.
    public static func screenBounds(
        viewSize: SIMD2<Float>,
        planeSize: SIMD2<Float>,
        camera: X3DCamera,
        model: X3DTransform,
        time: Float = 0
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        projectRect(
            (min: .zero, max: planeSize),
            viewSize: viewSize,
            planeSize: planeSize,
            camera: camera,
            model: model,
            time: time
        )
    }
}

private func multiply(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
    var result = [Float](repeating: 0, count: 16)
    for column in 0..<4 {
        for row in 0..<4 {
            var sum: Float = 0
            for k in 0..<4 { sum += lhs[k * 4 + row] * rhs[column * 4 + k] }
            result[column * 4 + row] = sum
        }
    }
    return result
}

private func mul4(_ m: [Float], _ v: SIMD4<Float>) -> SIMD4<Float> {
    var out = SIMD4<Float>(repeating: 0)
    for row in 0..<4 {
        out[row] = m[row] * v.x + m[4 + row] * v.y + m[8 + row] * v.z + m[12 + row] * v.w
    }
    return out
}

private func unproject(_ inv: [Float], ndc: SIMD2<Float>, clipZ: Float) -> SIMD3<Float> {
    let clip = SIMD4(ndc.x, ndc.y, clipZ, 1)
    let world = mul4(inv, clip)
    let w = max(abs(world.w), 1e-6) * (world.w < 0 ? -1 : 1)
    return SIMD3(world.x / w, world.y / w, world.z / w)
}

private func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

private func cross3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func invert(_ m: [Float]) -> [Float]? {
    var a = m
    var inv = [Float](repeating: 0, count: 16)
    inv[0] = 1; inv[5] = 1; inv[10] = 1; inv[15] = 1
    for col in 0..<4 {
        var pivot = col
        var best = abs(a[col * 4 + col])
        for row in (col + 1)..<4 {
            let value = abs(a[col * 4 + row])
            if value > best { best = value; pivot = row }
        }
        guard best > 1e-8 else { return nil }
        if pivot != col {
            for i in 0..<4 {
                a.swapAt(i * 4 + col, i * 4 + pivot)
                inv.swapAt(i * 4 + col, i * 4 + pivot)
            }
        }
        let diag = a[col * 4 + col]
        for i in 0..<4 {
            a[i * 4 + col] /= diag
            inv[i * 4 + col] /= diag
        }
        for row in 0..<4 where row != col {
            let factor = a[col * 4 + row]
            for i in 0..<4 {
                a[i * 4 + row] -= factor * a[i * 4 + col]
                inv[i * 4 + row] -= factor * inv[i * 4 + col]
            }
        }
    }
    return inv
}
