import Foundation
import Observation

/// One previously opened file. Local files keep a security-scoped bookmark so
/// sandboxed builds (the iOS app, a sandboxed macOS build) can reopen them;
/// remote files are reopened by URL through the engine's cache.
nonisolated struct RecentEntry: Identifiable, Hashable, Codable {
    enum Location: Hashable, Codable {
        case local(path: String, bookmark: Data?)
        case remote(url: URL)
    }

    let id: UUID
    var location: Location
    var name: String
    var authoredSize: String?
    var openedAt: Date

    var isRemote: Bool {
        if case .remote = location { true } else { false }
    }

    /// Identity of the underlying file, independent of the entry's own `id`,
    /// used to dedupe repeated opens.
    var dedupeKey: String {
        switch location {
        case .local(let path, _): "local:\(path)"
        case .remote(let url): "remote:\(url.absoluteString)"
        }
    }
}

/// Most-recent-first list of opened files, persisted to `UserDefaults` as JSON
/// (under `swift run` that resolves to the process-name preferences domain, so
/// the SPM executable and the app builds share the same code path).
@Observable
final class RecentsStore {
    private static let defaultsKey = "RiveInspector.recents"
    private static let limit = 20

    private(set) var entries: [RecentEntry] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Records a local file, refreshing its bookmark. Call while access to the
    /// URL is live so the bookmark captures the security scope.
    func recordLocal(_ url: URL, authoredSize: String?) {
        let bookmark = try? url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        insert(
            RecentEntry(
                id: UUID(),
                location: .local(path: url.path, bookmark: bookmark),
                name: url.lastPathComponent,
                authoredSize: authoredSize,
                openedAt: .now
            )
        )
    }

    func recordRemote(_ url: URL, authoredSize: String?) {
        let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        insert(
            RecentEntry(
                id: UUID(),
                location: .remote(url: url),
                name: name,
                authoredSize: authoredSize,
                openedAt: .now
            )
        )
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func remove(_ entry: RecentEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Resolves a local entry back to an openable URL: bookmark first, plain
    /// path as a fallback for unsandboxed builds. `nil` means the file is gone.
    func resolveLocalURL(of entry: RecentEntry) -> URL? {
        guard case .local(let path, let bookmark) = entry.location else { return nil }
        if let bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Whether the entry can be opened right now. Remote entries are always
    /// considered available — reachability is only knowable by loading.
    func isAvailable(_ entry: RecentEntry) -> Bool {
        switch entry.location {
        case .remote:
            return true
        case .local:
            guard let url = resolveLocalURL(of: entry) else { return false }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func insert(_ entry: RecentEntry) {
        entries.removeAll { $0.dedupeKey == entry.dedupeKey }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }
}
