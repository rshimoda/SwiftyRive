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
        for _ in 0..<200 where host.hasRive == false {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(host.hasRive, "the initial configuration must build")

        // Dropping the last reference on the main actor runs `isolated deinit`
        // inline, so teardown must be complete right here.
        view = nil
        #expect(host.hasRive == false, "deinit must release render state deterministically")
    }
}
