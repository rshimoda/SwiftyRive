import Foundation
import Metal
internal import RiveRuntime

/// Loads and caches parsed Rive documents.
///
/// The engine holds a cache of documents keyed by ``RiveSource``; concurrent
/// requests for the same source coalesce into one load. Documents render
/// through a single process-global `Worker` (see `SharedRiveWorker`, created
/// lazily on first load) that is shared by every engine instance.
///
/// Under system memory pressure the engine automatically evicts completed
/// cache entries (see ``isAutomaticEvictionEnabled``): loaded views keep
/// working because they retain their document; only re-loads pay a re-parse.
public actor RiveEngine {
    /// The shared engine used by ``RiveDocument/load(_:)`` and ``AsyncRiveView``.
    ///
    /// Uses `URLSession.shared` for remote sources.
    nonisolated public static let shared = RiveEngine()

    /// A cached load: the task plus whether it has completed successfully
    /// (marked when a caller consumes the loaded document). Failed loads are
    /// evicted outright, so `isFinished` implies success.
    private struct CacheEntry {
        let task: Task<RiveDocument, any Error>
        var isFinished = false
    }

    private var documents: [RiveSource: CacheEntry] = [:]

    /// The session used to download remote `.riv` sources.
    private let urlSession: URLSession

    /// The system memory-pressure signal driving automatic cache eviction.
    private let memoryPressureSource: any DispatchSourceMemoryPressure

    /// Whether the engine evicts completed cache entries when the system
    /// reports memory pressure (warning or critical). Defaults to `true`.
    ///
    /// Eviction only empties the cache: loaded views and instances keep
    /// working because they retain their ``RiveDocument`` directly; the next
    /// load of an evicted source re-parses the file. Disable with
    /// ``setAutomaticEvictionEnabled(_:)`` if you prefer to manage the cache
    /// yourself via ``removeDocument(for:)`` / ``removeAllDocuments()``.
    public private(set) var isAutomaticEvictionEnabled = true

    /// How many load tasks this engine has started. Test hook for verifying
    /// that concurrent requests coalesce into a single load.
    private(set) var loadCount = 0

    /// Creates an empty engine with its own document cache. (The render
    /// worker is process-global and shared by all engines.)
    ///
    /// Most callers should use ``shared`` so documents are cached process-wide.
    ///
    /// - Parameter urlSession: The session used to download remote `.riv`
    ///   sources. Defaults to `URLSession.shared`.
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }
        source.activate()
    }

    deinit {
        memoryPressureSource.cancel()
    }

    /// Enables or disables automatic cache eviction under system memory
    /// pressure (see ``isAutomaticEvictionEnabled``).
    public func setAutomaticEvictionEnabled(_ isEnabled: Bool) {
        isAutomaticEvictionEnabled = isEnabled
    }

    /// The sources currently held in the cache (including in-flight loads),
    /// in no particular order. Test hook for verifying cache contents.
    var cachedSources: [RiveSource] {
        Array(documents.keys)
    }

    /// Returns the document for `source`, loading and caching it on first request.
    ///
    /// In-flight loads are coalesced: concurrent calls with an equal source await
    /// the same underlying load. Failed loads are evicted so a later call retries.
    /// If ``removeDocument(for:)`` cancels an in-flight load this call was
    /// awaiting, the call transparently retries with a fresh load; only the
    /// caller's *own* cancellation surfaces as `CancellationError` — including
    /// when the caller was cancelled while the load itself succeeded, so a
    /// cancelled caller never receives (and acts on) a stale success.
    public func document(for source: RiveSource) async throws -> RiveDocument {
        while true {
            if let existing = documents[source]?.task {
                do {
                    let document = try await existing.value
                    // A cancelled caller must not consume a success meant for
                    // newer requests (the doc contract above).
                    try Task.checkCancellation()
                    markFinished(source, task: existing)
                    return document
                } catch is CancellationError {
                    // Propagate the caller's own cancellation; otherwise the
                    // entry was evicted mid-load, so clear it and retry.
                    try Task.checkCancellation()
                    if documents[source]?.task == existing {
                        documents[source] = nil
                    }
                    continue
                } catch {
                    // Evict before rethrowing: actor reentrancy means this
                    // awaiter can resume before (or instead of) the creator's
                    // eviction, and a retry must not re-hit a cached failure.
                    if documents[source]?.task == existing {
                        documents[source] = nil
                    }
                    throw error
                }
            }

            Log.engine.debug("Loading document for \(source.debugName, privacy: .public)")
            loadCount += 1
            let session = urlSession
            let task = Task { @MainActor in
                try await RiveDocument(source: source, urlSession: session)
            }
            documents[source] = CacheEntry(task: task)

            do {
                let document = try await task.value
                // Surface the caller's own cancellation even on success (the
                // doc contract above); the cached entry stays valid for others.
                try Task.checkCancellation()
                markFinished(source, task: task)
                return document
            } catch is CancellationError {
                // Either the caller itself was cancelled (surface it, keeping
                // a successful load cached), or the load was evicted mid-flight
                // by removeDocument (evict and retry).
                try Task.checkCancellation()
                if documents[source]?.task == task {
                    documents[source] = nil
                }
                continue
            } catch {
                // Only evict the task we created; a concurrent reload may have
                // replaced it with a fresh one.
                if documents[source]?.task == task {
                    documents[source] = nil
                }
                Log.engine.error("Failed to load \(source.debugName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    /// Marks a cache entry as successfully completed, provided the entry still
    /// holds the task the caller consumed (it may have been evicted or
    /// replaced by a reload in the meantime).
    private func markFinished(_ source: RiveSource, task: Task<RiveDocument, any Error>) {
        if documents[source]?.task == task {
            documents[source]?.isFinished = true
        }
    }

    /// Loads documents for all `sources` in parallel, returning the failures
    /// keyed by source.
    ///
    /// Successful loads land in the cache exactly as with ``document(for:)``;
    /// failed loads are evicted so a later request retries. An empty result
    /// means every source loaded (or was already cached).
    @discardableResult
    public func preloadDocuments(for sources: [RiveSource]) async -> [RiveSource: any Error] {
        await withTaskGroup(of: (RiveSource, (any Error)?).self) { group in
            for source in Set(sources) {
                group.addTask {
                    do {
                        _ = try await self.document(for: source)
                        return (source, nil)
                    } catch {
                        return (source, error)
                    }
                }
            }
            var failures: [RiveSource: any Error] = [:]
            for await (source, error) in group {
                if let error {
                    failures[source] = error
                }
            }
            return failures
        }
    }

    /// Evicts the cached document for `source`, cancelling an in-flight load.
    ///
    /// Existing ``RiveDocument`` references stay valid; only the cache entry is
    /// dropped. Callers currently awaiting a cancelled in-flight load retry
    /// with a fresh load (see ``document(for:)``).
    public func removeDocument(for source: RiveSource) {
        documents.removeValue(forKey: source)?.task.cancel()
    }

    /// Evicts all cached documents, cancelling any in-flight loads.
    public func removeAllDocuments() {
        for entry in documents.values {
            entry.task.cancel()
        }
        documents.removeAll()
    }

    // MARK: - Memory pressure

    /// Evicts every cache entry whose load has completed, keeping in-flight
    /// loads untouched. Called on system memory pressure; also a test hook.
    ///
    /// Safe at any time: views and instances retain their document directly,
    /// so nothing on screen is affected — only the next load of an evicted
    /// source re-parses the file.
    func evictCompletedDocuments() {
        let completed = documents.filter(\.value.isFinished).keys
        guard !completed.isEmpty else { return }
        Log.engine.debug("Evicting \(completed.count) completed cache entries")
        for source in completed {
            documents.removeValue(forKey: source)
        }
    }

    /// Reacts to a system memory-pressure event: evicts completed cache
    /// entries unless automatic eviction is disabled.
    func handleMemoryPressure() {
        guard isAutomaticEvictionEnabled else { return }
        Log.engine.debug("Memory pressure: evicting completed cache entries")
        evictCompletedDocuments()
    }
}

/// Lazily-created shared render worker used by every document the engine loads.
///
/// The runtime's `Worker` API is `@MainActor` and the type is not `Sendable`, so the
/// instance lives behind main-actor isolation rather than inside the engine actor.
@MainActor
enum SharedRiveWorker {
    private static var worker: RiveRuntime.Worker?

    /// Returns the shared worker, creating it on first use.
    ///
    /// Creation is synchronous (`Worker(device:)`), so concurrent first calls on the
    /// main actor cannot interleave and create two workers.
    static func shared() throws -> RiveRuntime.Worker {
        if let worker {
            return worker
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RiveLoadError.renderingUnavailable
        }
        Log.engine.debug("Creating shared Rive worker")
        let created = RiveRuntime.Worker(device: device)
        worker = created
        return created
    }
}
