import Foundation
import XLaser

public final class LiveLaserScript: @unchecked Sendable {
    public let descriptor: LaserDescriptor
    private let script: any LaserScriptable
    private let lock = NSLock()

    public init(_ script: any LaserScriptable) {
        self.script = script
        self.descriptor = script.descriptor
    }

    public func read(context: LaserReadContext, inputs: [String: LaserInput] = [:], output: inout Laser3DBuffer) throws {
        try lock.withLock {
            do {
                try script.read(context: context, inputs: inputs, output: &output)
            } catch {
                output.removeAll()
                throw error
            }
        }
    }
}
