import Foundation

/// Picking for X3D panels that live on the model-space `z = 0` plane
/// (axis-aligned cards / sheets). World size matches the encoder:
/// `planeSize / 100` units across (`half-extents = planeSize / 200`).
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
        let mvp = multiply(vp, model.matrix)
        guard let inv = invert(mvp) else { return nil }

        let ndc = SIMD2(
            screen.x / viewSize.x * 2 - 1,
            1 - screen.y / viewSize.y * 2
        )
        let near = unproject(inv, ndc: ndc, clipZ: 0)
        let far = unproject(inv, ndc: ndc, clipZ: 1)
        let dir = far - near
        guard abs(dir.z) > 1e-6 else { return nil }
        let t = -near.z / dir.z
        guard t >= 0, t <= 1 else { return nil }
        let local = near + dir * t

        let half = planeSize / (2 * pointsPerWorldUnit)
        guard abs(local.x) <= half.x + 1e-5, abs(local.y) <= half.y + 1e-5 else { return nil }

        return SIMD2(
            (local.x / half.x * 0.5 + 0.5) * planeSize.x,
            (0.5 - local.y / half.y * 0.5) * planeSize.y
        )
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
        guard viewSize.x > 0, viewSize.y > 0, planeSize.x > 0, planeSize.y > 0 else { return nil }
        let aspect = viewSize.x / viewSize.y
        let vp = camera.viewProjection(aspect: aspect, time: time)
        let mvp = multiply(vp, model.matrix)
        let half = planeSize / (2 * pointsPerWorldUnit)
        let corners: [SIMD3<Float>] = [
            SIMD3(-half.x, -half.y, 0), SIMD3(half.x, -half.y, 0),
            SIMD3(half.x, half.y, 0), SIMD3(-half.x, half.y, 0),
        ]
        var minS = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maxS = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var visible = false
        for corner in corners {
            let clip = mul4(mvp, SIMD4(corner.x, corner.y, corner.z, 1))
            guard clip.w > 1e-6 else { continue }
            let ndc = SIMD2(clip.x / clip.w, clip.y / clip.w)
            let screen = SIMD2(
                (ndc.x * 0.5 + 0.5) * viewSize.x,
                (0.5 - ndc.y * 0.5) * viewSize.y
            )
            minS = SIMD2(min(minS.x, screen.x), min(minS.y, screen.y))
            maxS = SIMD2(max(maxS.x, screen.x), max(maxS.y, screen.y))
            visible = true
        }
        return visible ? (minS, maxS) : nil
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
