import Foundation
import Dispatch
import XRender
import XUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// MCP endpoint for a running XAppSession. The transport binds loopback only.
/// The renderer supplies a capture of the same frame presented to the user.
public final class XUIMCPServer: @unchecked Sendable {
    public typealias State = @XUIActor @Sendable () async throws -> XUIMCPState
    public typealias Tap = @XUIActor @Sendable (String) async throws -> Bool
    public typealias Pointer = @XUIActor @Sendable (String, Double, Double) async throws -> Bool
    public typealias Capture = @Sendable () async throws -> XUIMCPImage
    /// Host-supplied text report about app internals that are not visible on screen.
    public typealias Diagnostics = @Sendable () async -> String
    private let diagnostics: Diagnostics?
    private let state: State
    private let tap: Tap
    private let pointer: Pointer
    private let capture: Capture
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    public let port: UInt16

    public init(port: UInt16 = 47321, state: @escaping State, tap: @escaping Tap,
                pointer: @escaping Pointer, capture: @escaping Capture, diagnostics: Diagnostics? = nil) {
        self.port = port; self.state = state; self.tap = tap; self.pointer = pointer; self.capture = capture
        self.diagnostics = diagnostics
    }

    public func start() throws {
        #if canImport(Darwin) || canImport(Glibc)
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw XUIMCPError.invalidRequest("Could not create MCP socket") }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 8) == 0 else { close(fd); throw XUIMCPError.invalidRequest("MCP port is unavailable") }
        lock.lock(); descriptor = fd; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd) }
        #else
        throw XUIMCPError.invalidRequest("MCP transport is not available on this platform")
        #endif
    }

    public func stop() {
        #if canImport(Darwin) || canImport(Glibc)
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
        #endif
    }
    deinit { stop() }

    #if canImport(Darwin) || canImport(Glibc)
    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.handle(client) }
        }
    }
    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        while bytes.count < 1_048_576, headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return }
            bytes.append(contentsOf: chunk.prefix(n))
            headerEnd = bytes.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd, let header = String(data: bytes[..<headerEnd.lowerBound], encoding: .utf8) else { return }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("POST /mcp ") == true else { sendResponse(fd, status: "405 Method Not Allowed", data: Data()); return }
        let headers: [String: String] = Dictionary(lines.dropFirst().compactMap { line in
            guard let split = line.firstIndex(of: ":") else { return nil }
            return (line[..<split].lowercased(), line[line.index(after: split)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, last in last })
        // MCP's loopback transport must not accept browser-originated requests.
        guard headers["origin"] == nil,
              let host = headers["host"], host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            sendResponse(fd, status: "403 Forbidden", data: Data()); return
        }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0, length <= 1_048_576 else { return }
        let bodyStart = headerEnd.upperBound
        while bytes.count - bodyStart < length {
            let n = recv(fd, &chunk, min(chunk.count, length - (bytes.count - bodyStart)), 0)
            guard n > 0 else { return }
            bytes.append(contentsOf: chunk.prefix(n))
        }
        let body = bytes.subdata(in: bodyStart..<(bodyStart + length))
        let sem = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task {
            box.value = await self.respond(body)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 30) == .success else { sendResponse(fd, status: "503 Service Unavailable", data: Data()); return }
        let response = box.value
        sendResponse(fd, status: response == nil ? "202 Accepted" : "200 OK", data: response ?? Data())
    }
    private func sendResponse(_ fd: Int32, status: String, data: Data) {
        var result = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        result.append(data)
        result.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                #if canImport(Glibc)
                let n = send(fd, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                #endif
                if n <= 0 { break }; sent += n
            }
        }
    }
    #endif

    private func respond(_ data: Data) async -> Data? {
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = request["method"] as? String else { return nil }
        guard let id = request["id"] else { return nil }
        let result: [String: Any]
        do {
            switch method {
            case "initialize":
                result = ["protocolVersion": "2025-11-25", "capabilities": ["tools": [:]], "serverInfo": ["name": "XUIHost", "version": "1.0"]]
            case "tools/list":
                result = ["tools": tools]
            case "tools/call":
                guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else {
                    throw XUIMCPError.invalidRequest("Missing tool name")
                }
                let args = params["arguments"] as? [String: Any] ?? [:]
                switch name {
                case "screen_state":
                    let encoded = try JSONEncoder().encode(try await state())
                    result = ["content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]]
                case "screen_tap":
                    guard let target = args["id"] as? String else { throw XUIMCPError.invalidRequest("Missing id") }
                    result = ["content": [["type": "text", "text": try await tap(target) ? "handled" : "not handled"]]]
                case "screen_pointer":
                    guard let phase = args["phase"] as? String, let x = args["x"] as? Double, let y = args["y"] as? Double else {
                        throw XUIMCPError.invalidRequest("Expected phase, x and y")
                    }
                    result = ["content": [["type": "text", "text": try await pointer(phase, x, y) ? "handled" : "not handled"]]]
                case "screen_capture":
                    let png = try await capture().png()
                    result = ["content": [["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]]]
                case "app_diagnostics":
                    guard let diagnostics else { throw XUIMCPError.invalidRequest("Unknown tool") }
                    result = ["content": [["type": "text", "text": await diagnostics()]]]
                default: throw XUIMCPError.invalidRequest("Unknown tool")
                }
            case "ping": result = [:]
            default: return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]])
        }
    }
    private var tools: [[String: Any]] {
        var tools: [[String: Any]] = [
        ["name": "screen_state", "description": "Read the current XUI controls and logical coordinates", "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "screen_tap", "description": "Tap a semantic control by id", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]],
        ["name": "screen_pointer", "description": "Send a pointer phase in logical coordinates", "inputSchema": ["type": "object", "properties": ["phase": ["type": "string", "enum": ["began", "moved", "ended", "cancelled"]], "x": ["type": "number"], "y": ["type": "number"]], "required": ["phase", "x", "y"]]],
        ["name": "screen_capture", "description": "Capture the rendered XUI surface as PNG", "inputSchema": ["type": "object", "properties": [:]]]
        ]
        if diagnostics != nil {
            tools.append(["name": "app_diagnostics", "description": "Read the host application's diagnostic report (internal state not shown on screen)", "inputSchema": ["type": "object", "properties": [:]]])
        }
        return tools
    }
}
private final class ResponseBox: @unchecked Sendable { var value: Data? }
