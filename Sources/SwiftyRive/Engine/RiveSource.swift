import Foundation

/// A description of where a Rive file's bytes come from.
///
/// `RiveSource` is a value type used both to load documents and as the cache key
/// inside ``RiveEngine`` — two equal sources always resolve to the same cached
/// ``RiveDocument``.
public nonisolated struct RiveSource: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case bundle(name: String, bundleURL: URL)
        case url(URL)
        case data(Data, identifier: String)
    }

    let storage: Storage

    /// A `.riv` file stored in a bundle.
    ///
    /// - Parameters:
    ///   - name: The resource name without the `.riv` extension.
    ///   - bundle: The bundle containing the resource. Defaults to `Bundle.main`.
    public static func bundle(_ name: String, in bundle: Bundle = .main) -> RiveSource {
        RiveSource(storage: .bundle(name: name, bundleURL: bundle.bundleURL))
    }

    /// A `.riv` file reachable at a URL (remote or file URL).
    public static func url(_ url: URL) -> RiveSource {
        RiveSource(storage: .url(url))
    }

    /// Raw `.riv` bytes that are already in memory.
    ///
    /// - Parameters:
    ///   - data: The contents of a `.riv` file.
    ///   - identifier: A stable identifier used for caching and logging.
    public static func data(_ data: Data, identifier: String) -> RiveSource {
        RiveSource(storage: .data(data, identifier: identifier))
    }

    /// A short human-readable description used in logs and error messages.
    var debugName: String {
        switch storage {
        case .bundle(let name, _):
            "bundle:\(name).riv"
        case .url(let url):
            "url:\(url.absoluteString)"
        case .data(let data, let identifier):
            "data:\(identifier) (\(data.count) bytes)"
        }
    }
}
