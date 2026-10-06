import Testing
import XUI

@Test func timeSyncKeepsFxAbsoluteAndRendererEpochRelative() {
    var sync = X3DTimeSync()
    #expect(sync.fxTime(at: 10) == 10)
    #expect(sync.rendererTime(at: 10) == 0)
    #expect(sync.rendererTime(at: 12.5) == 2.5)
    #expect(sync.fxTime(at: 12.5) == 12.5)
    #expect(sync.epoch == 10)
}
