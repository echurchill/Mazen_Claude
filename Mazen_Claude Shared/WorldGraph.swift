import Foundation

/// Route-keyed world identity (M15.0 — the World Graph, realized; see
/// `Mazen Docs/World Graph — Relational Worlds.md`).
///
/// A world is identified by the **edge you reach it through**, not just a name:
/// `WorldKey(destination:origin:)` — rendered in Eddie's `<destination>-<origin>` convention (D5).
/// Multiple keys may resolve to the **same** `GameState` (identity-bound edges: the moon seen from
/// earth IS the moon you can visit); different keys may resolve to **variants** (time periods,
/// alternate realities — the same temple door yielding a different interior per approach). Later
/// (M17), context can grow beyond origin to include what the player *knows* — doors re-aim.
struct WorldKey: Hashable, CustomStringConvertible {
    let destination: String
    let origin: String
    /// The canonical `<destination>-<origin>` name (D5).
    var description: String { "\(destination)-\(origin)" }
}

/// The universe: every world reachable by route, lazily created and **persistent** — scars
/// (twists, discoveries) keep for the app's lifetime. The world *stack* (Renderer) remains the
/// navigation history; this registry is the universe. Sky/counterpart lookups resolve through it
/// too — *what hangs in your sky is an edge, not a fact.*
final class WorldRegistry {
    private var worlds: [WorldKey: GameState] = [:]

    /// Resolve a key, creating the world on first reference (persistent thereafter).
    func world(for key: WorldKey, create: () -> GameState) -> GameState {
        if let w = worlds[key] { return w }
        let w = create()
        worlds[key] = w
        return w
    }

    /// Resolve only if it already exists (e.g. sky lookups that must not conjure worlds).
    func existing(_ key: WorldKey) -> GameState? { worlds[key] }

    /// Bind an additional route to an existing instance — the identity-bound edge
    /// (default per the design: bound; diverge only when the narrative wants it).
    func bind(_ key: WorldKey, to world: GameState) { worlds[key] = world }

    /// The instance carrying a given world *name*, whichever edge first created it. Sky bindings
    /// use this so the world overhead is the very one the player can walk into — bind a fresh
    /// build instead and you get two divergent copies of the same place, one of which silently
    /// stops matching the other the first time either is twisted.
    func anyNamed(_ name: String) -> GameState? {
        worlds.first { $0.key.destination == name }?.value
    }

    /// All *distinct* instances (multiple keys may share one), for whole-universe operations
    /// like the roundness debug dial.
    var allWorlds: [GameState] {
        var seen = Set<ObjectIdentifier>()
        return worlds.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}
