import CoreGraphics
import Foundation
internal import RiveRuntime

/// Reads artboard bounds through the legacy Objective-C `RiveFile` API.
/// The Concurrency runtime has no artboard size API, so this shim parses the
/// bytes once with the legacy runtime; callers cache the ``Catalog``, so each
/// document pays for at most one legacy parse. Legacy runtime types are
/// confined to this file and ``LegacySnapshotRenderer``.
///
/// Delete when rive-ios ships requestArtboardSize (rive-ios #323).
@MainActor
enum LegacyArtboardBounds {
    /// Every artboard size in a file, read in one legacy parse.
    struct Catalog {
        /// The authored size of the file's default artboard, if it has one.
        let defaultArtboardSize: CGSize?
        /// Authored sizes keyed by artboard name.
        let sizesByName: [String: CGSize]
    }

    /// Parses `data` with the legacy runtime and reads every artboard's
    /// authored bounds. `loadCdn` is off: only geometry is read. All legacy
    /// objects are released on return.
    static func readCatalog(from data: Data) throws -> Catalog {
        let file: RiveRuntime.RiveFile
        do {
            file = try RiveRuntime.RiveFile(data: data, loadCdn: false)
        } catch {
            throw RiveLoadError.parseFailed(description: error.localizedDescription)
        }

        var sizesByName: [String: CGSize] = [:]
        for name in file.artboardNames() {
            guard let artboard = try? file.artboard(fromName: name) else {
                Log.engine.error("Bounds shim could not open artboard '\(name, privacy: .public)'; skipping")
                continue
            }
            sizesByName[name] = artboard.bounds().size
        }

        let defaultArtboardSize = (try? file.artboard()).map { $0.bounds().size }
        return Catalog(defaultArtboardSize: defaultArtboardSize, sizesByName: sizesByName)
    }
}
