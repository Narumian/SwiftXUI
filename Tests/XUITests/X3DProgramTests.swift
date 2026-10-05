import Testing
@testable import XUI

private struct ProbeMesh: X3DProgram {
    typealias Body = Never
}

private struct AllViews: XView {
    var flag: Bool
    var body: some XView {
        Color.red
        if flag { Color.green } else { EmptyView() }
    }
}

private struct Mixed: X3DProgram {
    var flag: Bool
    var body: some X3DProgram {
        ProbeMesh()
        Color.red
        if flag { AllViews(flag: true) } else { ProbeMesh() }
    }
}

@Test @XUIActor
func viewOnlyBodiesStayViews() {
    let body = AllViews(flag: true).body
    #expect(body is TupleView)
}

@Test @XUIActor
func mixedBodiesBecomePrograms() throws {
    let body = Mixed(flag: false).body
    let tuple = try #require(body as? TupleX3D)
    #expect(tuple.children.count == 3)
    #expect(tuple.children[1] is Color)
    #expect(tuple.children[2] is ConditionalView<AllViews, ProbeMesh>)
}

@Test @XUIActor
func viewsAreProgramsInsideProgramBodies() {
    func accepts<P: X3DProgram>(_ program: P) -> Bool { true }
    #expect(accepts(AllViews(flag: false)))
}
