import Foundation

/// M17 Phase 0 — the player's knowledge, held **globally** (owned at the Renderer level beside the
/// world registry, NOT in any per-world `GameState`). Knowledge is the *player's*, not a world's,
/// and it must persist across every portal: understanding you gain in the temple interior must
/// still be true when you walk back out into the garden. That crossing-of-worlds is the whole
/// "knowledge-is-transportation" pillar (M17), so this deliberately lives outside the world stack.
///
/// It is also the substrate the Builder-glyph **comprehension gradient** reads from (see
/// [Builder Glyphs — 4D Shadows]): a glyph's caustic sharpens with `attunement(family:)`, which
/// rises as the player learns — but is clamped below 1, because a finite mind never fully reads a
/// hyper-dimensional message (Eddie's dog/"fetch" ceiling).
///
/// Phase 0 is just the container + its invariants; nothing sets or reads it yet in a way that
/// changes behaviour. The receive beat, the re-see, the knowledge-gated arch, and the caustic
/// shader all plug into this later.
final class PlayerKnowledge {

    /// Memory-motes the player has received, by id. Receiving one is the M17 "receive" beat.
    private(set) var receivedMemories: Set<String> = []

    /// Glyph / Builder-"word" identities the player has come to recognise, by id.
    private(set) var knownGlyphs: Set<String> = []

    /// Per-glyph-family attunement (how in-tune the player is with that family's forms). Drives
    /// the caustic sharpness. Stored explicitly so learning can raise it gradually and unevenly.
    private var familyAttunement: [String: Float] = [:]

    /// You never fully understand the Builders — attunement is capped below 1 (the irreducible
    /// residual fog of the finite-vs-hyper-dimensional gap). Tunable; the *curve* toward it is a
    /// prototyping question for the caustic spike.
    static let attunementCeiling: Float = 0.9

    // MARK: - Memories

    /// Receive a memory-mote. Returns `true` if it was newly received (so callers can fire the
    /// "receive" beat only on the first time), `false` if already held.
    @discardableResult
    func receive(memory id: String) -> Bool {
        receivedMemories.insert(id).inserted
    }

    func hasMemory(_ id: String) -> Bool { receivedMemories.contains(id) }

    // MARK: - Glyphs

    /// Come to recognise a glyph / Builder word. Idempotent.
    func learn(glyph id: String) { knownGlyphs.insert(id) }

    func knows(glyph id: String) -> Bool { knownGlyphs.contains(id) }

    // MARK: - Attunement (the comprehension gradient)

    /// Raise attunement to a glyph family, clamped to `[0, attunementCeiling]` — it rises toward,
    /// but never reaches, full clarity.
    func attune(family: String, by amount: Float) {
        let current = familyAttunement[family] ?? 0
        familyAttunement[family] = min(Self.attunementCeiling, max(0, current + amount))
    }

    /// 0 (mushy first-contact) … ≤ `attunementCeiling`. What the caustic shader reads to set a
    /// glyph's sharpness for this player.
    func attunement(family: String) -> Float { familyAttunement[family] ?? 0 }

    // MARK: - Introspection

    /// True before the player has learned or received anything (fresh game).
    var isEmpty: Bool {
        receivedMemories.isEmpty && knownGlyphs.isEmpty && familyAttunement.isEmpty
    }
}
