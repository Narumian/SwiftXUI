import Testing
@testable import XUI

private final class EnvironmentObjectModel {
    let color: XColorValue

    init(color: XColorValue) {
        self.color = color
    }
}

private struct EnvironmentObjectProbe: XView {
    @EnvironmentObject var model: EnvironmentObjectModel

    var body: some XView {
        Color(model.color)
    }
}

@Test @XUIActor func environmentObjectResolvesAndCanBeReplacedByExactType() async {
    var environment = EnvironmentValues()
    environment.environmentObject(EnvironmentObjectModel(color: .red))

    let firstSurface = RecordingCanvas()
    await LayoutHost(canvas: Size(width: 10, height: 10), environment: environment)
        .render(EnvironmentObjectProbe(), into: firstSurface)
    #expect(firstSurface.fills.first?.color == .red)

    environment.environmentObject(EnvironmentObjectModel(color: .blue))
    let secondSurface = RecordingCanvas()
    await LayoutHost(canvas: Size(width: 10, height: 10), environment: environment)
        .render(EnvironmentObjectProbe(), into: secondSurface)
    #expect(secondSurface.fills.first?.color == .blue)
}
