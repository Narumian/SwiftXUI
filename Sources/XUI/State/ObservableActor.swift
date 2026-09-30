/// Generates async `Binding` projections for stored mutable properties of an actor.
@attached(member, names: arbitrary)
public macro ObservableActor() =
    #externalMacro(module: "XUIMacros", type: "ObservableActorMacro")
