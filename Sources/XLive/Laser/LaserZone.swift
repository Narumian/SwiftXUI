import Foundation
import XUI

/// A zone: the part of the laser path that is common to the outputs it feeds. It holds
/// what is tuned live (the mastering in 3D and the scanner settings that follow the
/// projection) and nothing of what runs underneath it: the ring, the producer and the
/// output pumps are kept by `LaserOutputStreams` for the zone's `id`.
///
/// Like any `XLive`, a zone is a value the host updates serially and retains. It encodes
/// what a saved session needs to bring it back. A chain does not read the zone itself, it
/// reads `LaserLive` boxes, because it is read from a real-time pump that must not wait
/// for an update; the host `publish`es the zone into the boxes after it has updated it.
///
/// One output belongs to one zone.
public struct LaserZone: XLive, Equatable {
    /// Names the zone to `LaserOutputStreams`, and to an application's own zone.
    public var id: UUID
    /// The master filter, in 3D, before the projection.
    public var mastering: LaserMastering
    /// Projection, screen, padding, corners and resampling.
    public var scanner: LaserScannerSettings
    /// The highest point rate the zone makes samples at. Outputs that cannot take that
    /// rate play it through their own rate conversion.
    public var maximumPointRate: UInt32

    public init(id: UUID = UUID(), mastering: LaserMastering = LaserMastering(),
                scanner: LaserScannerSettings = LaserScannerSettings(), maximumPointRate: UInt32 = 30_000) {
        self.id = id; self.mastering = mastering; self.scanner = scanner; self.maximumPointRate = max(1, maximumPointRate)
    }

    public mutating func update(context: LiveUpdateContext) async {
        await mastering.update(context: context)
    }

    /// Writes the zone's settings to the boxes a `LaserScannerChain` reads, so the chain
    /// follows them from its next frame.
    public func publish(scanner box: LaserLive<LaserScannerSettings>, mastering masteringBox: LaserLive<LaserMastering>) {
        box.value = scanner
        masteringBox.value = mastering
    }

    /// A zone has no interface of its own yet.
    public var body: some XView { EmptyView() }
}
