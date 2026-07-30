import Foundation
import Testing
@testable import SwiftyRive

/// Shared access to the committed test fixtures.
///
/// `data_binding_test.riv` comes from the MIT-licensed rive-ios repository
/// (Tests/Assets, tag 6.22.0). Its root view model "Test" carries every
/// supported property kind plus nested view models "Nested" and "Default";
/// dump the full tree with `RiveDocument.dumpViewModels()`.
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
