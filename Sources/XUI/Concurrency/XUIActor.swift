/// The isolation domain for XUI declaration, state, and lifecycle work.
///
/// Platform shells may call into this actor from their own main-actor or
/// event-loop code. Renderer backends receive value snapshots separately and
/// do not need to run on this actor.
@globalActor
public actor XUIActor {
    public static let shared = XUIActor()
}
