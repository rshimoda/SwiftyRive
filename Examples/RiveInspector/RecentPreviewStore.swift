import CoreGraphics
import Foundation
import SwiftyRive

/// Renders and caches the artwork shown on the recents tiles.
///
/// Previews come from the package's headless snapshot API, so a grid of twenty
/// files costs twenty bitmaps instead of twenty live Metal views. Renders are
/// serialized — a tile scrolling into view queues behind the render already in
/// flight — and every finished frame is kept for the rest of the session, so
/// scrolling back never re-renders. Nothing is written to disk: a cold launch
/// re-renders, which is cheap and always matches the current file on disk.
final class RecentPreviewStore {
    /// Point size each snapshot is rendered at, matching the tiles' 4:3 preview
    /// area. Wider than the widest tile, so the bitmap still has pixels to
    /// spare on a 3x screen without holding a 3x-sized image per entry.
    private static let renderSize = CGSize(width: 240, height: 180)
    private static let renderScale: CGFloat = 2
    /// Seconds the state machine is advanced before the frame is captured.
    /// Files that open on an intro animation are still empty at zero; half a
    /// second in, the artwork that gives the file its identity is on screen.
    private static let renderTime: TimeInterval = 0.5

    private let recents: RecentsStore
    /// Finished renders, failures included as `nil`, so a file that can't be
    /// rendered isn't retried every time its tile scrolls back into view.
    private var images: [RecentEntry.ID: CGImage?] = [:]
    private var renders: [RecentEntry.ID: Task<CGImage?, Never>] = [:]
    /// Tail of the render queue: each new render awaits this one before
    /// starting, so appearing tiles never stampede the shared renderer.
    private var tail: Task<Void, Never>?

    init(recents: RecentsStore) {
        self.recents = recents
    }

    /// The already-rendered preview for `entry`, if there is one. Lets a tile
    /// that scrolls back into view show its artwork without a loading frame.
    func cachedImage(for entry: RecentEntry) -> CGImage? {
        images[entry.id] ?? nil
    }

    /// The preview for `entry`, rendering it on first request and reusing the
    /// result afterwards. `nil` means the file could not be resolved,
    /// downloaded, or rendered — the caller shows a placeholder.
    func image(for entry: RecentEntry) async -> CGImage? {
        if let cached = images[entry.id] { return cached }
        if let render = renders[entry.id] { return await render.value }

        let render = Task<CGImage?, Never> { [recents, previous = tail] in
            await previous?.value
            return await Self.render(entry, resolvedBy: recents)
        }
        renders[entry.id] = render
        tail = Task { _ = await render.value }

        let image = await render.value
        renders[entry.id] = nil
        images[entry.id] = .some(image)
        return image
    }

    /// Loads the entry's document through the shared engine and poses a single
    /// frame from it. Local files are only readable inside their security
    /// scope, so the whole load-and-render runs within it.
    private static func render(_ entry: RecentEntry, resolvedBy recents: RecentsStore) async
        -> CGImage? {
        guard let url = openableURL(of: entry, in: recents) else { return nil }
        return await url.withSecurityScopedAccess { () -> CGImage? in
            guard let document = try? await RiveDocument.load(.url(url)) else { return nil }
            return try? await document.snapshot(
                size: renderSize,
                fit: .contain,
                scale: renderScale,
                at: renderTime
            )
        }
    }

    private static func openableURL(of entry: RecentEntry, in recents: RecentsStore) -> URL? {
        switch entry.location {
        case .remote(let url): url
        case .local: recents.resolveLocalURL(of: entry)
        }
    }
}
