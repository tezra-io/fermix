import AppKit
import Foundation

/// Preloaded NSImage cache for the mascot's PNG layers.
///
/// `MascotImage` previously read every layer from the bundle on every view
/// evaluation. Under a continuous `TimelineView` that turned into hundreds
/// of disk reads per second. Preloading once at app launch removes that
/// hidden cost and makes the per-frame path a dict lookup.
@MainActor
final class PetAssetCache {
    static let shared = PetAssetCache()

    private var images: [String: NSImage] = [:]

    private init() {}

    /// Load every PNG in `Resources/PetExpressions/` into memory.
    /// `pet_idle_decor` and `pet_listening_decor` do not exist in the repo
    /// today — `load` silently tolerates missing assets, and
    /// `MascotImage`'s optional layer rendering already handles absence.
    func preload() {
        let expressions = ["idle", "listening", "thinking", "speaking"]
        let layers = ["body", "ring", "face", "decor"]
        for expression in expressions {
            for layer in layers {
                load("pet_\(expression)_\(layer)")
            }
        }
        load("pet_ball")
    }

    func image(_ name: String) -> NSImage? {
        images[name]
    }

    private func load(_ name: String) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            return
        }
        images[name] = img
    }
}
