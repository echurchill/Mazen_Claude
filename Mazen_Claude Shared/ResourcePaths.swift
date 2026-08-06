import Foundation

/// Where the imported models and skyboxes live — resolved, never hardcoded.
///
/// Both of these used to be absolute paths to Eddie's machine
/// (`/Volumes/Code Work/xCode work/Mazen_Claude/…`), which meant the game ran on exactly one
/// computer. A clone compiled, passed every check, and then came up with no portal frames, no
/// dressed walls, no vegetation and no sky — the loaders degrade to empty rather than crashing, so
/// it looked like a level-design decision rather than a missing folder.
///
/// Resolution order, first hit wins:
///
///  1. **The app bundle.** A build phase copies exactly what git tracks into `Resources/`, so a
///     built app is self-contained and works under the sandbox, off any machine.
///  2. **The source tree**, derived from `#filePath` at compile time. This is what makes a fresh
///     clone work in Xcode *anywhere* — no volume name, no user name, no configuration step. It is
///     also the reason the dev loop survives if the copy phase is ever disabled.
///
/// If neither exists the paths still resolve (to the source-tree guess) and the loaders log their
/// failures individually, which is the behaviour that has always been there.
enum ResourcePaths {

    /// The repository root, from this file's own compile-time path: `…/Mazen_Claude Shared/ResourcePaths.swift`
    /// → up two. Not a runtime lookup — the literal is baked in when this file is compiled, so it
    /// points at whatever machine and path built the binary.
    private static let sourceRoot: URL =
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func resolve(_ name: String) -> String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return sourceRoot.appendingPathComponent(name).path
    }

    /// Imported model packs (`AssetRegistry`). Only the slice the loader reads is tracked and
    /// copied — see `.gitignore` and `Mazen Docs/Master Roadmap.md` §7.
    static let models = resolve("Mazen_Models")

    /// Composite skybox PNGs, cycled by the `L` debug key.
    static let skyboxes = resolve("Skyboxes")

    /// One line at boot saying where the art came from, because "no props" and "props from the
    /// wrong place" look identical on screen.
    static func log() {
        let bundled = Bundle.main.resourceURL.map { models.hasPrefix($0.path) } ?? false
        NSLog("[ResourcePaths] models: %@ (%@)", models, bundled ? "bundled" : "source tree")
    }
}
