import Foundation
import XRender
import XUI

public struct XUIMCPControl: Codable, Sendable {
    public let id: String
    public let label: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct XUIMCPState: Codable, Sendable {
    public let width: Float
    public let height: Float
    public let controls: [XUIMCPControl]
}

public enum XUIMCPError: Error, LocalizedError {
    case noFrame, controlNotFound, captureUnavailable, invalidImage, invalidRequest(String)
    public var errorDescription: String? {
        switch self {
        case .noFrame: "No rendered frame is available"
        case .controlNotFound: "Control not found"
        case .captureUnavailable: "Screen capture is unavailable"
        case .invalidImage: "Invalid image buffer"
        case .invalidRequest(let text): text
        }
    }
}

@XUIActor
public extension XAppSession {
    /// A snapshot of semantic controls in the last rendered frame.
    func mcpState() throws -> XUIMCPState {
        guard let frame = lastFrame else { throw XUIMCPError.noFrame }
        var controls = frame.layout.controls.map { item in
                XUIMCPControl(id: item.control.id.rawValue, label: item.control.label,
                              x: item.rect.x, y: item.rect.y, width: item.rect.width, height: item.rect.height)
            }
        for item in frame.layout.tapGestures {
            guard let id = item.id, !controls.contains(where: { $0.id == id }) else { continue }
            controls.append(XUIMCPControl(id: id, label: item.label ?? id, x: item.rect.x,
                                          y: item.rect.y, width: item.rect.width, height: item.rect.height))
        }
        return XUIMCPState(width: host.size.width, height: host.size.height, controls: controls)
    }

    /// Route automation through the same pointer path as a user's input.
    func mcpTap(id: String) throws -> Bool {
        guard let frame = lastFrame else { throw XUIMCPError.noFrame }
        let target = frame.layout.tapGestures.first(where: { $0.id == id })?.rect
            ?? frame.layout.controls.first(where: { $0.control.id.rawValue == id })?.rect
        guard let target else { throw XUIMCPError.controlNotFound }
        let point = RenderPoint(x: Float(target.midX), y: Float(target.midY))
        let began = pointer(PointerEvent(phase: .began, position: point))
        let ended = pointer(PointerEvent(phase: .ended, position: point))
        return began && ended
    }
}

/// RGBA framebuffer supplied by the host's renderer, encoded as PNG without a
/// platform image API. Rows are top-down and alpha is unpremultiplied.
public struct XUIMCPImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }
    public func png() throws -> Data {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              rgba.count == width * height * 4 else { throw XUIMCPError.invalidImage }
        var scan = [UInt8](); scan.reserveCapacity(rgba.count + height)
        for row in 0..<height {
            scan.append(0)
            let start = row * width * 4
            scan.append(contentsOf: rgba[start..<(start + width * 4)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var position = 0
        while position < scan.count {
            let count = min(65535, scan.count - position)
            z.append(position + count == scan.count ? 1 : 0)
            let n = UInt16(count); let complement = ~n
            z += [UInt8(n & 255), UInt8(n >> 8), UInt8(complement & 255), UInt8(complement >> 8)]
            z.append(contentsOf: scan[position..<(position + count)])
            position += count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in scan { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        appendBE((b << 16) | a, to: &z)
        var out: [UInt8] = [137,80,78,71,13,10,26,10]
        var header = [UInt8](); appendBE(UInt32(width), to: &header); appendBE(UInt32(height), to: &header)
        header += [8, 6, 0, 0, 0]
        appendChunk("IHDR", header, to: &out); appendChunk("IDAT", z, to: &out); appendChunk("IEND", [], to: &out)
        return Data(out)
    }
}

private func appendBE(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes += [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
}
private func appendChunk(_ name: String, _ data: [UInt8], to output: inout [UInt8]) {
    appendBE(UInt32(data.count), to: &output)
    let content = Array(name.utf8) + data
    output += content
    var crc: UInt32 = 0xffffffff
    for byte in content {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
    }
    appendBE(crc ^ 0xffffffff, to: &output)
}
