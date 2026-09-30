import Testing
import XRender
import XUI
@testable import XUIHost

@Test func hostRendersAnXViewIntoAFrame() {
    let host = XUIHost(size: RenderSize(width: 320, height: 180))
    let frame = host.render(Color.red, time: 1.25)

    #expect(frame.scene.commands.count == 1)
    #expect(frame.scene.authoringCanvas == RenderSize(width: 320, height: 180))
    #expect(frame.layout.regions.isEmpty)
}

@Test func hostKeepsStateStoreAcrossFrames() {
    let host = XUIHost(size: RenderSize(width: 320, height: 180))
    _ = host.render(Color.blue, time: 1)
    let frame = host.render(Color.green, time: 2)

    #expect(frame.scene.commands.count == 1)
}
