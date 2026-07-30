import Foundation
import Testing
@testable import SwiftyRive

/// Headless tests for runtime property discovery and ``RiveDynamicInstance``:
/// discovery, seeding, the lenient subscripts, and safe misuse.
struct DynamicInstanceTests {
    @Test func discoveryFindsTheKnownFixtureTree() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let properties = try await document.dynamicProperties()
        let kindsByPath = Dictionary(uniqueKeysWithValues: properties.map { ($0.path, $0.kind) })

        #expect(kindsByPath["Number"] == .number)
        #expect(kindsByPath["Boolean"] == .bool)
        #expect(kindsByPath["String"] == .string)
        #expect(kindsByPath["Color"] == .color)
        #expect(kindsByPath["Enum"] == .enum(cases: ["Baz", "Bar", "Foo"]))
        #expect(kindsByPath["Trigger Red"] == .trigger)
        #expect(kindsByPath["Trigger Green"] == .trigger)
        #expect(kindsByPath["Trigger Blue"] == .trigger)

        // Nested view models are flattened into forward-slash paths.
        #expect(kindsByPath["Nested/String"] == .string)
        #expect(kindsByPath["Nested/DeeperNested/String"] == .string)
        #expect(kindsByPath["SecondNested/String"] == .string)
        #expect(kindsByPath["SecondNested/DeeperNested/String"] == .string)

        // List and image properties surface as display-only unsupported kinds.
        #expect(kindsByPath["List"] == .unsupported(typeName: "list"))
        #expect(kindsByPath["Image"] == .unsupported(typeName: "image"))
    }

    @Test func discoveryWorksFromAnExplicitViewModel() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let properties = try await document.dynamicProperties(viewModel: "Nested")
        let paths = Set(properties.map(\.path))
        #expect(paths == ["String", "DeeperNested/String"])
    }

    @Test func discoveryRejectsAnUnknownViewModel() async throws {
        let document = try await Fixtures.dataBindingDocument()
        await #expect(throws: RiveSchemaError.self) {
            _ = try await document.dynamicProperties(viewModel: "Missing")
        }
    }

    @Test func discoveryRejectsAnUnknownArtboard() async throws {
        let document = try await Fixtures.dataBindingDocument()
        do {
            _ = try await document.makeDynamicInstance(artboard: "Missing")
            Issue.record("Expected artboardNotFound to be thrown")
        } catch let RiveLoadError.artboardNotFound(name, available) {
            #expect(name == "Missing")
            #expect(available == ["Artboard"])
        }
    }

    @Test func instancePropertiesMatchStandaloneDiscovery() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()
        let standalone = try await document.dynamicProperties()
        #expect(instance.properties == standalone)
    }

    @Test func mirrorIsSeededWithFileDefaults() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()

        // The fixture's default instance has "Foo" as the enum default.
        #expect(instance[enumValue: "Enum"] == "Foo")

        // Every supported value property is synchronously readable.
        #expect(instance[number: "Number"] != nil)
        #expect(instance[bool: "Boolean"] != nil)
        #expect(instance[string: "String"] != nil)
        #expect(instance[color: "Color"] != nil)
        #expect(instance[string: "Nested/DeeperNested/String"] != nil)
    }

    @Test func subscriptsRoundTrip() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()

        instance[number: "Number"] = 42
        #expect(instance[number: "Number"] == 42)

        let toggled = !(instance[bool: "Boolean"] ?? false)
        instance[bool: "Boolean"] = toggled
        #expect(instance[bool: "Boolean"] == toggled)

        instance[string: "String"] = "Hello dynamic"
        #expect(instance[string: "String"] == "Hello dynamic")

        let color = RiveColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        instance[color: "Color"] = color
        #expect(instance[color: "Color"] == color)

        instance[enumValue: "Enum"] = "Bar"
        #expect(instance[enumValue: "Enum"] == "Bar")

        instance[string: "Nested/DeeperNested/String"] = "deep"
        #expect(instance[string: "Nested/DeeperNested/String"] == "deep")
    }

    @Test func wrongKindReadsReturnNil() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()

        #expect(instance[number: "String"] == nil)
        #expect(instance[bool: "Number"] == nil)
        #expect(instance[string: "Missing/Path"] == nil)
        #expect(instance[color: "Enum"] == nil)
        #expect(instance[enumValue: "Trigger Red"] == nil)
    }

    @Test func wrongKindWritesAreNoOps() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()

        let number = instance[number: "Number"]
        instance[bool: "Number"] = true
        instance[string: "Number"] = "nope"
        #expect(instance[number: "Number"] == number)

        // Unknown enum cases and nil assignments are ignored too.
        instance[enumValue: "Enum"] = "NotACase"
        #expect(instance[enumValue: "Enum"] == "Foo")
        instance[number: "Number"] = nil
        #expect(instance[number: "Number"] == number)
    }

    /// A change made on the runtime side, bypassing the mirror, must flow back
    /// into the mirror through the per-path value stream (the same delivery
    /// path an animation-driven write takes).
    @Test func runtimeOriginatedChangesReachTheMirror() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()

        PropertyTransport.write(.string("runtime-originated"), at: "String", to: instance.viewModelInstance)

        // Headless there is no display link; poll with direct reads until
        // the stream delivers into the mirror.
        var delivered = false
        for _ in 0..<100 {
            _ = try? await PropertyTransport.readValue(of: .string, at: "String", from: instance.viewModelInstance)
            if instance[string: "String"] == "runtime-originated" {
                delivered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delivered, "The value stream never delivered a runtime-side change into the mirror")
    }

    @Test func fireOnANonTriggerIsASafeNoOp() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let instance = try await document.makeDynamicInstance()
        instance.fire("Number")
        instance.fire("Missing")
        instance.fire("Trigger Red")
    }
}
