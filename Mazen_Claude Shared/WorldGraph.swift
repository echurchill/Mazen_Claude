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

    /// Names that must resolve to ONE instance however they are reached. The prologue's scenes are
    /// the case that matters: there is one Scene 2, and Scene 6 returns to *it* — "Scene 6 must use
    /// the actual persisted state of Scene 2, not a visually similar duplicate. The scene depends on
    /// trust. If the world resets here, the theme collapses."
    ///
    /// The policy lived in the Renderer, which cannot be reached from the test harness — so the one
    /// property Scene 6 is built on had no test. It is universe policy, not rendering.
    var singleInstanceNames: Set<String> = []

    /// Resolve by route, honouring `singleInstanceNames`: a single-instance world is bound to this
    /// new edge as well, so both routes lead to the same place with the same scars.
    func resolve(destination: String, origin: String, create: () -> GameState) -> GameState {
        let key = WorldKey(destination: destination, origin: origin)
        if let w = worlds[key] { return w }
        let w = (singleInstanceNames.contains(destination) ? anyNamed(destination) : nil) ?? create()
        worlds[key] = w
        return w
    }

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


/// The catalogue of places a portal can lead, and what a signpost says about each.
///
/// These two lists are INDEX-ALIGNED — a portal Prop stores an index into `destinations`, and its
/// signpost samples the same index out of `labels`. They lived on the Renderer, which the test
/// harness cannot compile, so nothing could check that they stayed the same length: adding Scene 6
/// as destination 15 left `labels` with 15 entries, and its signpost sampled a slice that does not
/// exist and came back reading "Moon" (Eddie). Here they can be tested, and are.
///
/// APPEND ONLY. A portal prop stores the index, so reordering silently re-aims every existing door.
enum WorldCatalog {
    static let destinations = ["moon", "temple-interior", "natural", "garden", "gallery",
                               "gallery-dungeons", "gallery-nature", "gallery-ruins", "gallery-megakit",
                               "portal-hub",   // index 9 — the labeled hub (reached by the ` key)
                               "scene-2",      // index 10 — prologue Scene 2
                               "scene-4",      // index 11 — prologue Scene 4
                               "scene-1",      // index 12 — prologue Scene 1, the opening
                               "scene-3",      // index 13 — prologue Scene 3, the interior
                               "scene-5",      // index 14 — prologue Scene 5, the pale world
                               "scene-6",      // index 15 — NOT a world of its own: Scene 2 returned
                                               // to from Scene 5, resolved to that instance.
                               "gallery-cyberpunk"]   // index 16 — the Cyberpunk kit, laid out to be
                                                      // looked at (Eddie asks for a gallery per pack)

    /// Sign text, index-aligned with `destinations`. Index 9 is the hub itself, which never signposts
    /// itself — the blank keeps the two lists in step.
    static let labels = ["Moon", "Temple Interior", "Natural World", "The Garden", "Gallery",
                         "Dungeons Gallery", "Nature Gallery", "Ruins Gallery", "MegaKit Gallery",
                         "", "Scene 2 Four Corners", "Scene 4 First Turn", "Scene 1 First Clearing",
                         "Scene 3 Heart of the World", "Scene 5 Broken Meridian",
                         "Scene 6 World Remembered", "Cyberpunk Gallery"]

    /// The prologue's scenes, whose hub doors wear DARSIT red rather than TARDIS blue, and which are
    /// single-instance: one Scene 2, however it is reached.
    static let prologueIDs: Set<Int> = [10, 11, 12, 13, 14, 15]
}
