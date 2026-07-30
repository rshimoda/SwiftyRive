import Foundation
import Metal
internal import RiveRuntime

/// Loads and caches parsed Rive documents.
///
/// The engine holds a cache of documents keyed by ``RiveSource``; concurrent
/// requests for the same source coalesce into one load. Documents render
/// through a single process-global `Worker` (see `SharedRiveWorker`, created
/// lazily on first load) that is shared by every engine instance.
public actor RiveEngine {
    /// The shared engine used by ``RiveDocument/load(_:)`` and ``AsyncRiveView``.
    nonisolated public static let shared = RiveEngine()

    private var documents: [RiveSource: Task<RiveDocument, any Error>] = [:]

    /// How many load tasks this engine has started. Test hook for verifying
    /// that concurrent requests coalesce into a single load.
    private(set) var loadCount = 0

    /// Creates an empty engine with its own document cache. (The render
    /// worker is process-global and shared by all engines.)
    ///
    /// Most callers should use ``shared`` so documents are cached process-wide.
    public init() {}

    /// The sources currently held in the cache (including in-flight loads),
    /// in no particular order. Intended for introspection and tests.
    public var cachedSources: [RiveSource] {
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
            if let existing = documents[source] {
                do {
                    let document = try await existing.value
                    // A cancelled caller must not consume a success meant for
                    // newer requests (the doc contract above).
                    try Task.checkCancellation()
                    return document
                } catch is CancellationError {
                    // Propagate the caller's own cancellation; otherwise the
                    // entry was evicted mid-load, so clear it and retry.
                    try Task.checkCancellation()
                    if documents[source] == existing {
                        documents[source] = nil
                    }
                    continue
                } catch {
                    // Evict before rethrowing: actor reentrancy means this
                    // awaiter can resume before (or instead of) the creator's
                    // eviction, and a retry must not re-hit a cached failure.
                    if documents[source] == existing {
                        documents[source] = nil
                    }
                    throw error
                }
            }

            Log.engine.debug("Loading document for \(source.debugName, privacy: .public)")
            loadCount += 1
            let task = Task { @MainActor in
                try await RiveDocument(source: source)
            }
            documents[source] = task

            do {
                let document = try await task.value
                // Surface the caller's own cancellation even on success (the
                // doc contract above); the cached entry stays valid for others.
                try Task.checkCancellation()
                return document
            } catch is CancellationError {
                // Either the caller itself was cancelled (surface it, keeping
                // a successful load cached), or the load was evicted mid-flight
                // by removeDocument (evict and retry).
                try Task.checkCancellation()
                if documents[source] == task {
                    documents[source] = nil
                }
                continue
            } catch {
                // Only evict the task we created; a concurrent reload may have
                // replaced it with a fresh one.
                if documents[source] == task {
                    documents[source] = nil
                }
                Log.engine.error("Failed to load \(source.debugName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
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
        documents.removeValue(forKey: source)?.cancel()
    }

    /// Evicts all cached documents, cancelling any in-flight loads.
    public func removeAllDocuments() {
        for task in documents.values {
            task.cancel()
        }
        documents.removeAll()
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
