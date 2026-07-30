import Foundation
import Testing
@testable import SwiftyRive

/// Headless tests for ``RiveNativeView``'s deterministic teardown: the core's
/// `isolated deinit` runs teardown on the main actor before stored properties
/// are released (rive-ios #442/#418/#453).
struct NativeViewTests {
    @Test func deinitTearsDownRenderStateDeterministically() async throws {
        let document = try await Fixtures.dataBindingDocument()
        var view: RiveNativeView? = RiveNativeView(document: document)
        let host = try #require(view?.renderHostForTesting)

        // Wait (bounded) for the initial configuration to build.
        let built = await pollUntil { host.hasRive }
        #expect(built, "the initial configuration must build")

        // Dropping the last reference runs `isolated deinit` on the main actor,
        // but the runtime may enqueue it rather than run it inline (SE-0371),
        // so allow a bounded wait for the teardown to land.
        view = nil
        let torn = await pollUntil { host.hasRive == false }
        #expect(torn, "deinit must release render state on the main actor")
    }
}
