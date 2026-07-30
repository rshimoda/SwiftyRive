import Foundation
import SwiftUI
import Testing
@testable import SwiftyRive

/// Tests for ``RiveInstance`` that work headless (no rendering view):
/// seeding, the local mirror, subscript/binding round trips, and diagnostics.
/// Animation-originated updates need a rendering view and are not covered here.
struct InstanceTests {
    @Test func makeInstanceSeedsMirrorWithFileDefaults() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        // The fixture's "Default" instance has "Foo" as the enum default.
        #expect(instance[\.mode] == .foo)

        // Every seeded key is synchronously readable without crashing.
        _ = instance[\.text]
        _ = instance[\.number]
        _ = instance[\.flag]
        _ = instance[\.color]
        _ = instance[\.nestedText]
        _ = instance[\.deepText]
    }

    @Test func makeInstanceWorksWithDefaultViewModel() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: DefaultViewModelSchema.self)
        #expect(instance[\.mode] == .foo)
    }

    @Test func makeInstanceAcceptsAKnownArtboardName() async throws {
        let document = try await Fixtures.dataBindingDocument()
        // "Artboard" is the fixture's only artboard, so its default view model
        // is the same one a nil artboard resolves to.
        let instance = try await document.makeInstance(of: DefaultViewModelSchema.self, artboard: "Artboard")
        #expect(instance[\.mode] == .foo)
    }

    @Test func makeInstanceRejectsAnUnknownArtboardName() async throws {
        let document = try await Fixtures.dataBindingDocument()
        do {
            _ = try await document.makeInstance(of: DefaultViewModelSchema.self, artboard: "Missing")
            Issue.record("Expected artboardNotFound to be thrown")
        } catch let RiveLoadError.artboardNotFound(name, available) {
            #expect(name == "Missing")
            #expect(available == ["Artboard"])
        }
    }

    @Test func subscriptWritesUpdateTheMirror() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        instance[\.text] = "Hello from SwiftyRive"
        #expect(instance[\.text] == "Hello from SwiftyRive")

        instance[\.number] = 42
        #expect(instance[\.number] == 42)

        let toggled = !instance[\.flag]
        instance[\.flag] = toggled
        #expect(instance[\.flag] == toggled)

        let color = RiveColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        instance[\.color] = color
        #expect(instance[\.color] == color)

        instance[\.mode] = .bar
        #expect(instance[\.mode] == .bar)

        instance[\.deepText] = "deep"
        #expect(instance[\.deepText] == "deep")
    }

    @Test func bindingRoundTrips() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        let binding = instance.binding(for: \.number)
        binding.wrappedValue = 7
        #expect(instance[\.number] == 7)
        #expect(binding.wrappedValue == 7)

        instance[\.number] = 9
        #expect(binding.wrappedValue == 9)
    }

    /// A runtime-side change bypassing the mirror must reach the typed
    /// instance's mirror through the value stream.
    @Test func runtimeOriginatedChangesReachTheMirror() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        PropertyTransport.write(.string("runtime-originated"), at: "String", to: instance.viewModelInstance)

        var delivered = false
        for _ in 0..<100 {
            _ = try? await PropertyTransport.readValue(of: .string, at: "String", from: instance.viewModelInstance)
            if instance[\.text] == "runtime-originated" {
                delivered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered, "The value stream never delivered a runtime-side change into the mirror")
    }

    @Test func firingATriggerDoesNotCrashHeadless() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)
        // Without a rendering view there is nothing to advance, but firing must
        // be safe and the firings stream must be constructible.
        instance.fire(\.triggerRed)
        _ = instance.firings(of: \.triggerRed)
    }

    // MARK: - Trigger streams

    /// `fire(_:)` must surface on the instance's own `firings(of:)` stream.
    /// Trigger delivery does not need state machine advancing, so it works headless.
    @Test func fireDeliversToItsOwnFiringsStream() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)
        let stream = instance.firings(of: \.triggerRed)

        let consumer = Task {
            for await _ in stream {
                return true
            }
            return false
        }
        instance.fire(\.triggerRed)

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            consumer.cancel()
        }
        let received = await consumer.value
        watchdog.cancel()
        #expect(received, "fire(_:) never reached the firings(of:) stream")
    }

    /// Every `firings(of:)` call returns an independent stream: ending one
    /// consumer must not end the other, and both receive events.
    @Test func multipleFiringsCallsReturnIndependentStreams() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        let first = instance.firings(of: \.triggerRed)
        let second = instance.firings(of: \.triggerRed)

        let firstConsumer = Task {
            for await _ in first {
                return true
            }
            return false
        }
        let secondConsumer = Task {
            for await _ in second {
                return true
            }
            return false
        }

        instance.fire(\.triggerRed)

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            firstConsumer.cancel()
            secondConsumer.cancel()
        }
        let firstReceived = await firstConsumer.value
        let secondReceived = await secondConsumer.value
        watchdog.cancel()
        #expect(firstReceived && secondReceived, "both independent streams must observe the firing")
    }

    /// Cancelling one subscriber terminates only that subscriber's stream —
    /// a survivor still receives later firings.
    @Test func terminatingOneFiringsStreamLeavesOthersAlive() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeInstance(of: FixtureSchema.self)

        let doomed = instance.firings(of: \.triggerRed)
        let survivor = instance.firings(of: \.triggerRed)

        let doomedConsumer = Task {
            for await _ in doomed {}
        }
        doomedConsumer.cancel()
        await doomedConsumer.value

        let survivorConsumer = Task {
            for await _ in survivor {
                return true
            }
            return false
        }
        instance.fire(\.triggerRed)

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            survivorConsumer.cancel()
        }
        let received = await survivorConsumer.value
        watchdog.cancel()
        #expect(received, "the surviving stream must keep receiving firings")
    }

    /// Deallocating the instance finishes every vended firings stream
    /// deterministically.
    @Test func firingsStreamsFinishOnInstanceDeinit() async throws {
        let document = try await Fixtures.dataBindingDocument()
        var instance: RiveInstance<FixtureSchema>? = try await document.makeInstance(of: FixtureSchema.self)
        let stream = try #require(instance).firings(of: \.triggerRed)

        let consumer = Task {
            for await _ in stream {}
            // Distinguish a natural finish from the watchdog cancelling us.
            return Task.isCancelled == false
        }

        instance = nil

        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            consumer.cancel()
        }
        let finished = await consumer.value
        watchdog.cancel()
        #expect(finished, "firings streams must finish when the instance deallocates")
    }

    @Test func diagnosticsDumpContainsFullTree() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let dump = await RiveDiagnostics.dumpViewModels(of: document)

        #expect(dump.contains("Test"))
        #expect(dump.contains("Nested"))
        #expect(dump.contains("DeeperNested"))
        #expect(dump.contains("Number: number"))
        #expect(dump.contains("String: string"))
        #expect(dump.contains("Trigger Red: trigger"))
        #expect(dump.contains("Foo"))
        #expect(dump.contains("Bar"))
        #expect(dump.contains("Baz"))
    }
}

struct RiveColorTests {
    @Test func componentsAreClamped() {
        let color = RiveColor(red: -1, green: 2, blue: 0.5, alpha: 3)
        #expect(color == RiveColor(red: 0, green: 1, blue: 0.5, alpha: 1))
    }

    @Test func nonFiniteComponentsAreMappedToTheRange() {
        // NaN and -inf map to 0, +inf maps to 1: `max(.nan, 0)` would
        // propagate NaN and trap later in the UInt8 runtime conversion.
        let nan = RiveColor(red: .nan, green: .nan, blue: .nan, alpha: .nan)
        #expect(nan == RiveColor(red: 0, green: 0, blue: 0, alpha: 0))

        let infinite = RiveColor(red: .infinity, green: -.infinity, blue: .infinity, alpha: .infinity)
        #expect(infinite == RiveColor(red: 1, green: 0, blue: 1, alpha: 1))

        // The runtime conversion (the original trap site) must not trap.
        _ = nan.runtimeColor
        _ = infinite.runtimeColor
    }

    @Test func runtimeConversionRoundTripsWithinQuantization() {
        let color = RiveColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let roundTripped = RiveColor(runtimeColor: color.runtimeColor)
        #expect(abs(roundTripped.red - color.red) < 1.0 / 255)
        #expect(abs(roundTripped.green - color.green) < 1.0 / 255)
        #expect(abs(roundTripped.blue - color.blue) < 1.0 / 255)
        #expect(roundTripped.alpha == 1)
    }

    @Test func swiftUIColorInitResolvesComponents() {
        let color = RiveColor(SwiftUI.Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 1))
        #expect(abs(color.red - 0.2) < 0.01)
        #expect(abs(color.green - 0.4) < 0.01)
        #expect(abs(color.blue - 0.6) < 0.01)
    }
}
