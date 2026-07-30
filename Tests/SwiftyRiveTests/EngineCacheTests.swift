import Foundation
import Testing
@testable import SwiftyRive

/// Cache behavior of ``RiveEngine``: identity, coalescing, eviction, preload,
/// and eviction-during-load robustness.
///
/// Every test uses its own `RiveEngine()` so state never leaks between tests
/// (or into the shared engine other suites use).
struct EngineCacheTests {
    private func fixtureSource(identifier: String = "cache.data_binding_test.riv") throws -> RiveSource {
        .data(try Fixtures.data(named: "data_binding_test"), identifier: identifier)
    }

    private func corruptSource() throws -> RiveSource {
        .data(try Fixtures.data(named: "corrupt"), identifier: "cache.corrupt.riv")
    }

    @Test func sameSourceReturnsTheSameDocumentObject() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource()

        let first = try await engine.document(for: source)
        let second = try await engine.document(for: source)
        #expect(first === second)
        #expect(await engine.loadCount == 1)
    }

    @Test func concurrentRequestsCoalesceIntoOneLoad() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.coalescing.riv")

        async let first = engine.document(for: source)
        async let second = engine.document(for: source)
        let (a, b) = try await (first, second)

        #expect(a === b)
        #expect(await engine.loadCount == 1)
    }

    @Test func removeDocumentEvictsSoReloadCreatesANewObject() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.eviction.riv")

        let first = try await engine.document(for: source)
        await engine.removeDocument(for: source)
        let second = try await engine.document(for: source)

        #expect(first !== second)
        #expect(await engine.loadCount == 2)
    }

    @Test func removeAllDocumentsEvictsEverything() async throws {
        let engine = RiveEngine()
        let sourceA = try fixtureSource(identifier: "cache.removeAll.a.riv")
        let sourceB = try fixtureSource(identifier: "cache.removeAll.b.riv")

        _ = try await engine.document(for: sourceA)
        _ = try await engine.document(for: sourceB)
        #expect(await engine.cachedSources.count == 2)

        await engine.removeAllDocuments()
        #expect(await engine.cachedSources.isEmpty)
    }

    @Test func cachedSourcesReflectsCacheContents() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.sources.riv")

        #expect(await engine.cachedSources.isEmpty)
        _ = try await engine.document(for: source)
        #expect(await engine.cachedSources == [source])
        await engine.removeDocument(for: source)
        #expect(await engine.cachedSources.isEmpty)
    }

    @Test func failedLoadIsEvictedSoALaterCallRetries() async throws {
        let engine = RiveEngine()
        let source = try corruptSource()

        await #expect(throws: RiveLoadError.self) {
            _ = try await engine.document(for: source)
        }
        #expect(await engine.cachedSources.isEmpty)
        // The retry runs a fresh load (which fails again, but is not coalesced
        // onto the dead task).
        await #expect(throws: RiveLoadError.self) {
            _ = try await engine.document(for: source)
        }
        #expect(await engine.loadCount == 2)
    }

    @Test func preloadReportsFailuresPerSourceAndCachesTheValidOnes() async throws {
        let engine = RiveEngine()
        let valid = try fixtureSource(identifier: "cache.preload.valid.riv")
        let invalid = try corruptSource()

        let failures = await engine.preloadDocuments(for: [valid, invalid])

        #expect(failures.count == 1)
        #expect(failures[invalid] is RiveLoadError)
        #expect(failures[valid] == nil)

        // The valid document is cached: fetching it again is a cache hit.
        let loadsAfterPreload = await engine.loadCount
        let document = try await engine.document(for: valid)
        #expect(document.artboardNames.isEmpty == false)
        #expect(await engine.loadCount == loadsAfterPreload)
        #expect(await engine.cachedSources == [valid])
    }

    @Test func evictionDuringLoadStillReturnsADocumentToTheCaller() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.evict-in-flight.riv")

        // Evict mid-load: the caller must end up with a document from a fresh
        // retried load, never a stray CancellationError.
        let loader = Task {
            try await engine.document(for: source)
        }
        // Wait until the in-flight load is registered so the eviction cancels
        // it rather than racing ahead of it.
        while await engine.cachedSources.isEmpty {
            await Task.yield()
        }
        await engine.removeDocument(for: source)

        let document = try await loader.value
        #expect(document.artboardNames.isEmpty == false)
        #expect(await engine.loadCount == 2, "the evicted load must be retried with a fresh load")
    }

    @Test func callerCancellationSurfacesInsteadOfRetryingForever() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.caller-cancel.riv")

        let loader = Task {
            try await engine.document(for: source)
        }
        // Arrange the retry path exactly as above: evict the registered
        // in-flight load, forcing the caller onto its retry loop…
        while await engine.cachedSources.isEmpty {
            await Task.yield()
        }
        await engine.removeDocument(for: source)

        // …then cancel the caller itself: its own cancellation must surface
        // as CancellationError (the escape hatch that prevents infinite retry).
        loader.cancel()
        await #expect(throws: CancellationError.self) {
            try await loader.value
        }
    }

    // MARK: - Preload edges

    @Test func preloadWithDuplicateSourcesLoadsOnlyOnce() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.preload.duplicates.riv")

        let failures = await engine.preloadDocuments(for: [source, source, source])

        #expect(failures.isEmpty)
        #expect(await engine.loadCount == 1)
        #expect(await engine.cachedSources == [source])
    }

    @Test func preloadWithEmptyInputDoesNothing() async throws {
        let engine = RiveEngine()

        let failures = await engine.preloadDocuments(for: [])

        #expect(failures.isEmpty)
        #expect(await engine.loadCount == 0)
        #expect(await engine.cachedSources.isEmpty)
    }

    @Test func preloadOfAnAlreadyCachedSourceIsACacheHit() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.preload.cached.riv")

        _ = try await engine.document(for: source)
        let failures = await engine.preloadDocuments(for: [source])

        #expect(failures.isEmpty)
        #expect(await engine.loadCount == 1)
    }

    @Test func allFailingPreloadLeavesTheCacheEmpty() async throws {
        let engine = RiveEngine()
        let invalid = try corruptSource()

        let failures = await engine.preloadDocuments(for: [invalid])

        #expect(failures.count == 1)
        #expect(failures[invalid] is RiveLoadError)
        #expect(await engine.cachedSources.isEmpty)
    }

    // MARK: - Memory-pressure eviction

    @Test func evictCompletedDocumentsEmptiesTheCacheAndKeepsDocumentsAlive() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.evict-completed.riv")

        let document = try await engine.document(for: source)
        await engine.evictCompletedDocuments()
        #expect(await engine.cachedSources.isEmpty)

        // The evicted document object keeps working (views retain documents
        // directly); only a re-load pays a fresh parse.
        #expect(document.artboardNames.isEmpty == false)
        let reloaded = try await engine.document(for: source)
        #expect(reloaded !== document)
        #expect(await engine.loadCount == 2)
    }

    @Test func evictCompletedDocumentsDoesNotCancelInFlightLoads() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.evict-inflight-kept.riv")

        let loader = Task {
            try await engine.document(for: source)
        }
        while await engine.cachedSources.isEmpty {
            await Task.yield()
        }
        await engine.evictCompletedDocuments()

        // Whether or not the load managed to finish before the eviction, the
        // caller gets its document from the one load it started: an in-flight
        // entry is never cancelled (unlike removeDocument(for:), which forces
        // a retry and a second load).
        let document = try await loader.value
        #expect(document.artboardNames.isEmpty == false)
        #expect(await engine.loadCount == 1)
    }

    @Test func memoryPressureEvictsCompletedEntries() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.pressure.riv")

        _ = try await engine.document(for: source)
        #expect(await engine.isAutomaticEvictionEnabled)
        await engine.handleMemoryPressure()
        #expect(await engine.cachedSources.isEmpty)
    }

    @Test func disablingAutomaticEvictionMakesPressureANoOp() async throws {
        let engine = RiveEngine()
        let source = try fixtureSource(identifier: "cache.pressure-optout.riv")

        _ = try await engine.document(for: source)
        await engine.setAutomaticEvictionEnabled(false)
        #expect(await engine.isAutomaticEvictionEnabled == false)
        await engine.handleMemoryPressure()
        #expect(await engine.cachedSources == [source])

        // Re-enabling restores the default behavior.
        await engine.setAutomaticEvictionEnabled(true)
        await engine.handleMemoryPressure()
        #expect(await engine.cachedSources.isEmpty)
    }

    // MARK: - URLSession injection

    @Test func remoteLoadGoesThroughTheInjectedSession() async throws {
        FixtureServingURLProtocol.setStubbedData(try Fixtures.data(named: "data_binding_test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureServingURLProtocol.self]
        let engine = RiveEngine(urlSession: URLSession(configuration: configuration))
        // The .invalid TLD guarantees no real network traffic even on a miss.
        let url = try #require(URL(string: "https://swifty-rive.stub.invalid/data_binding_test.riv"))

        let requestsBefore = FixtureServingURLProtocol.requestCount
        let document = try await engine.document(for: .url(url))

        #expect(document.artboardNames.isEmpty == false)
        #expect(FixtureServingURLProtocol.requestCount > requestsBefore)
    }
}

/// A `URLProtocol` that serves pre-registered bytes for every request, so
/// remote-source tests exercise the engine's injected `URLSession` without
/// touching the network.
nonisolated final class FixtureServingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubbedData = Data()
    nonisolated(unsafe) private static var _requestCount = 0

    static func setStubbedData(_ data: Data) {
        lock.withLock { stubbedData = data }
    }

    static var requestCount: Int {
        lock.withLock { _requestCount }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.lock.withLock {
            Self._requestCount += 1
            return Self.stubbedData
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Headless robustness tests for ``RiveRenderHost``: rapid configuration
/// switching and repeated mount/teardown cycles. Without a window there is no
/// Metal drawing, so these verify state-machine correctness only.
@MainActor
struct RenderHostSwitchingTests {
    private func configuration(
        document: RiveDocument,
        artboard: String?,
        fit: RiveFit = .contain
    ) -> RiveRenderHost.Configuration {
        RiveRenderHost.Configuration(
            document: document,
            artboardName: artboard,
            stateMachineName: nil,
            fit: fit,
            boundViewModelInstance: nil
        )
    }

    @Test func applyBuildsARiveForTheConfiguration() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let host = RiveRenderHost()

        await host.apply(configuration(document: document, artboard: nil))

        #expect(host.hasRive)
        #expect(host.error == nil)
    }

    @Test func rapidSwitchingSettlesOnTheLastConfiguration() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let artboardName = try #require(document.artboardNames.first)
        let host = RiveRenderHost()

        // Mimic `.task(id:)`: each new configuration cancels the previous
        // apply before starting its own.
        var previous: Task<Void, Never>?
        for flip in 0..<20 {
            previous?.cancel()
            let artboard: String? = flip.isMultiple(of: 2) ? nil : artboardName
            let config = configuration(document: document, artboard: artboard)
            previous = Task { await host.apply(config) }
        }
        await previous?.value

        // The last configuration (flip 19 → named artboard) must have won.
        #expect(host.appliedArtboardName == artboardName)
        #expect(host.hasRive)
        #expect(host.error == nil)
    }

    @Test func staleFailureCannotClobberANewerConfiguration() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let host = RiveRenderHost()

        // A failing configuration immediately superseded by a valid one: the
        // stale failure must not surface once the valid build has committed.
        let failing = Task {
            await host.apply(configuration(document: document, artboard: "no-such-artboard"))
        }
        failing.cancel()
        await host.apply(configuration(document: document, artboard: nil))
        await failing.value

        #expect(host.hasRive)
        #expect(host.error == nil)
    }

    @Test func cancelledRebuildIsNotSwallowedByAFitOnlyReapply() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let artboardName = try #require(document.artboardNames.first)
        let host = RiveRenderHost()

        // Scene A commits.
        await host.apply(configuration(document: document, artboard: nil))
        #expect(host.hasRive)
        #expect(host.committedArtboardName == nil)

        // Scene B's apply is cancelled mid-flight (mimics `.task(id:)` being
        // restarted by a fit-only environment change, which is part of the
        // task identity). Yield until the apply has recorded B as the
        // requested configuration so the cancel lands after that point.
        let applyB = Task {
            await host.apply(configuration(document: document, artboard: artboardName))
        }
        while host.appliedArtboardName != artboardName {
            await Task.yield()
        }
        applyB.cancel()
        await applyB.value

        // Re-applying B with a different fit must notice that B never
        // committed and rebuild it — a fast path comparing only the last
        // *requested* configuration would just set the fit on A's stale
        // `Rive` and scene B would never appear.
        await host.apply(configuration(document: document, artboard: artboardName, fit: .cover))

        #expect(host.hasRive)
        #expect(host.error == nil)
        #expect(host.committedArtboardName == artboardName)
    }

    @Test func repeatedMountAndTeardownDoesNotCrash() async throws {
        let document = try await Fixtures.dataBindingDocument()

        for _ in 0..<50 {
            let host = RiveRenderHost()
            await host.apply(configuration(document: document, artboard: nil))
            #expect(host.hasRive)
            host.teardown()
            #expect(host.hasRive == false)
            #expect(host.appliedArtboardName == nil)
            #expect(host.error == nil)
        }
    }

    @Test func teardownIsIdempotentAndReapplyWorks() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let host = RiveRenderHost()

        await host.apply(configuration(document: document, artboard: nil))
        host.teardown()
        host.teardown()
        #expect(host.hasRive == false)

        // A view that reappears re-applies its configuration.
        await host.apply(configuration(document: document, artboard: nil))
        #expect(host.hasRive)
    }
}
