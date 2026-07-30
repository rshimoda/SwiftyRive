import Foundation
import Testing
@testable import SwiftyRive

/// Shared access to the committed test fixtures.
///
/// `data_binding_test.riv` comes from the MIT-licensed rive-ios repository
/// (Tests/Assets, tag 6.22.0). Its root view model "Test" carries every
/// supported property kind plus nested view models "Nested" and "Default";
/// dump the full tree with `RiveDocument.dumpViewModels()`.
///
/// Invariant: tests must never evict from `RiveEngine.shared` — suites that
/// need parse-count determinism (BoundsShimTests) rely on shared-cache entries
/// staying put; use a private `RiveEngine()` for eviction scenarios.
enum Fixtures {
    static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "riv", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    /// Loads (and caches, via the shared engine) the data-binding fixture.
    static func dataBindingDocument() async throws -> RiveDocument {
        let data = try data(named: "data_binding_test")
        return try await RiveDocument.load(.data(data, identifier: "fixture.data_binding_test.riv"))
    }

    enum FixtureError: Error {
        case missing(String)
    }
}

// MARK: - Async assertion helpers

/// Polls `condition` until it holds or `deadline` elapses, running `pump`
/// before every check (e.g. a direct runtime read that nudges a value stream).
/// Returns whether the condition was observed in time.
func pollUntil(
    deadline: Duration = .seconds(10),
    pump: () async -> Void = {},
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + deadline
    while true {
        await pump()
        if condition() {
            return true
        }
        guard clock.now < end else {
            return false
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Awaits the first event of `stream`, giving up after `timeout`.
///
/// Returns `true` when an event arrived, `false` when the stream finished
/// without one or the timeout elapsed first.
func firstEvent(of stream: AsyncStream<Void>, within timeout: Duration = .seconds(5)) async -> Bool {
    let consumer = Task {
        for await _ in stream {
            return true
        }
        return false
    }
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        consumer.cancel()
    }
    defer { watchdog.cancel() }
    return await consumer.value
}

/// Awaits `stream` finishing on its own, giving up after `timeout`.
///
/// Returns `true` only for a natural finish — a timeout (which cancels the
/// consuming task) reports `false`.
func streamFinishes(_ stream: AsyncStream<Void>, within timeout: Duration = .seconds(5)) async -> Bool {
    let consumer = Task {
        for await _ in stream {}
        // Distinguish a natural finish from the watchdog cancelling us.
        return Task.isCancelled == false
    }
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        consumer.cancel()
    }
    defer { watchdog.cancel() }
    return await consumer.value
}

/// Asserts that `body` throws `RiveLoadError.artboardNotFound` carrying both
/// payload fields: the failing name and the list of available artboards.
func expectArtboardNotFound(
    name: String,
    available: [String],
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("Expected artboardNotFound to be thrown", sourceLocation: sourceLocation)
    } catch let RiveLoadError.artboardNotFound(thrownName, thrownAvailable) {
        #expect(thrownName == name, sourceLocation: sourceLocation)
        #expect(thrownAvailable == available, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected artboardNotFound, got \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - Schemas under test

nonisolated enum FixtureEnum: String, RiveEnum {
    case foo = "Foo"
    case bar = "Bar"
    case baz = "Baz"
}

/// Happy-path schema covering every supported property kind, a nested path,
/// and a deeply nested path, addressed by explicit view model name.
nonisolated struct FixtureSchema: RiveSchema {
    static var viewModelName: String? { "Test" }

    let text = RiveKey<String>("String")
    let number = RiveKey<Double>("Number")
    let flag = RiveKey<Bool>("Boolean")
    let color = RiveKey<RiveColor>("Color")
    let mode = RiveKey<FixtureEnum>("Enum")
    let nestedText = RiveKey<String>("Nested/String")
    let deepText = RiveKey<String>("Nested/DeeperNested/String")
    let triggerRed = RiveTriggerKey("Trigger Red")
}

/// Same shape but relying on the default artboard's default view model
/// ("Test" in the fixture).
nonisolated struct DefaultViewModelSchema: RiveSchema {
    let number = RiveKey<Double>("Number")
    let mode = RiveKey<FixtureEnum>("Enum")
}
