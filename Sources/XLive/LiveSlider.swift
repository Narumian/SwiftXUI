import XUI

/// Horizontal control for a host-owned LiveParameter. The host updates the same
/// binding each frame and provides a binding safe for gesture callbacks.
public struct LiveSlider: XView, Sendable {
    private let parameter: Binding<LiveParameter>
    private let knobSize: Double

    public init(parameter: Binding<LiveParameter>, knobSize: Double = 24) {
        self.parameter = parameter
        self.knobSize = knobSize.isFinite ? max(1, knobSize) : 24
    }

    public var body: some XView {
        GeometryReader { geometry in
            let width = max(0, geometry.width)
            let height = max(0, geometry.height)
            let diameter = min(knobSize, width, height)
            let travel = max(0, width - diameter)
            let current = parameter.wrappedValue
            let x = diameter / 2 + current.normalizedValue * travel
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2, fill: .gray)
                    .frame(width: width, height: 4)
                    .position(x: width / 2, y: height / 2)
                Circle(fill: .white)
                    .frame(width: diameter, height: diameter)
                    .gesture(TapGesture().onEnded {
                        var next = parameter.wrappedValue
                        next.releaseManualControl()
                        parameter.wrappedValue = next
                    })
                    .position(x: x, y: height / 2)
            }
            .gesture(DragGesture(minimumDistance: 4).onChanged { drag in
                guard travel > 0 else { return }
                let normalized = (drag.location.x - geometry.frame.origin.x - diameter / 2) / travel
                var next = parameter.wrappedValue
                next.setNormalizedManualValue(normalized)
                parameter.wrappedValue = next
            })
        }
    }
}
