import Foundation
import XShader

enum X3DStep {
    case op(X3DOp)
    case view(LayoutNode)
}

/// The flattened form of a program tree. Draws, blits and views written
/// outside a `Pass` are gathered into an implicit pass onto the output.
struct X3DWalk {
    private(set) var steps: [X3DStep] = []
    var scope: Int
    private var explicitPassDepth = 0
    private var implicitPassOpen = false

    init(scope: Int) { self.scope = scope }

    func resource(_ name: String) -> X3DResourceID {
        X3DResourceID(scope: scope, name: name)
    }

    mutating func emit(_ op: X3DOp) {
        switch op {
        case .draw, .blit:
            openImplicitPassIfNeeded()
        case .beginPass:
            closeImplicitPass()
            explicitPassDepth += 1
        case .endPass:
            explicitPassDepth -= 1
        case .resource, .compute:
            closeImplicitPass()
        }
        steps.append(.op(op))
    }

    mutating func view(_ node: LayoutNode) {
        openImplicitPassIfNeeded()
        steps.append(.view(node))
    }

    mutating func finish() {
        closeImplicitPass()
    }

    private mutating func openImplicitPassIfNeeded() {
        guard explicitPassDepth == 0, !implicitPassOpen else { return }
        implicitPassOpen = true
        steps.append(.op(.beginPass(target: .output, load: .load)))
    }

    private mutating func closeImplicitPass() {
        guard implicitPassOpen else { return }
        implicitPassOpen = false
        steps.append(.op(.endPass))
    }
}

protocol _PrimitiveX3D {
    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async
}

@XUIActor
func walkX3D(_ program: any X3DProgram, id: StateIdentity, store: StateStore,
             into walk: inout X3DWalk) async {
    if let view = program as? any XView {
        for node in await lower(view, id: id, store: store) {
            walk.view(node)
        }
        return
    }
    if let primitive = program as? _PrimitiveX3D {
        await primitive._walk(id: id, store: store, into: &walk)
        return
    }
    let childID = id.child(type: type(of: program))
    let outer = walk.scope
    walk.scope = childID.hashValue
    if var dynamic = program as? any DynamicProperty {
        dynamic.update(id: childID, store: store)
        await walkX3D((dynamic as! any X3DProgram).body, id: childID, store: store, into: &walk)
    } else {
        await walkX3D(program.body, id: childID, store: store, into: &walk)
    }
    walk.scope = outer
}

extension TupleX3D: _PrimitiveX3D {
    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        for (i, child) in children.enumerated() {
            await walkX3D(child, id: id.child(type: type(of: child), index: i), store: store, into: &walk)
        }
    }
}

extension OptionalView: _PrimitiveX3D {
    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        guard let wrapped else { return }
        await walkX3D(wrapped, id: id, store: store, into: &walk)
    }
}

extension ConditionalView: _PrimitiveX3D {
    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        switch storage {
        case .first(let program): await walkX3D(program, id: id, store: store, into: &walk)
        case .second(let program): await walkX3D(program, id: id, store: store, into: &walk)
        }
    }
}

extension ArrayView: _PrimitiveX3D {
    @XUIActor
    func _walk(id: StateIdentity, store: StateStore, into walk: inout X3DWalk) async {
        for (i, element) in elements.enumerated() {
            await walkX3D(element, id: id.child(type: type(of: element), index: i), store: store, into: &walk)
        }
    }
}
