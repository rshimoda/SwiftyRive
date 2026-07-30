import Foundation
import Testing
@testable import SwiftyRive

struct SchemaValidationTests {
    // MARK: - Happy path

    @Test func fullSchemaValidatesAgainstFixture() async throws {
        let document = try await Fixtures.dataBindingDocument()
        try await document.validate(FixtureSchema.self)
    }

    @Test func defaultViewModelSchemaValidatesAgainstFixture() async throws {
        let document = try await Fixtures.dataBindingDocument()
        try await document.validate(DefaultViewModelSchema.self)
    }

    // MARK: - Artboard-aware resolution

    @Test func validateAcceptsAKnownArtboardName() async throws {
        let document = try await Fixtures.dataBindingDocument()
        // "Artboard" is the fixture's only artboard, so anchoring the default
        // view model to it resolves the same root as the file default does.
        try await document.validate(DefaultViewModelSchema.self, artboard: "Artboard")
        try await document.validate(FixtureSchema.self, artboard: "Artboard")
    }

    @Test func validateRejectsAnUnknownArtboardName() async throws {
        let document = try await Fixtures.dataBindingDocument()
        await expectArtboardNotFound(name: "Missing", available: ["Artboard"]) {
            try await document.validate(DefaultViewModelSchema.self, artboard: "Missing")
        }
    }

    @Test func validateRejectsAnUnknownArtboardEvenWithAnExplicitViewModelName() async throws {
        let document = try await Fixtures.dataBindingDocument()
        await expectArtboardNotFound(name: "Missing", available: ["Artboard"]) {
            try await document.validate(FixtureSchema.self, artboard: "Missing")
        }
    }

    // MARK: - Issue variants

    nonisolated struct WrongViewModelSchema: RiveSchema {
        static var viewModelName: String? { "DoesNotExist" }
        let number = RiveKey<Double>("Number")
    }

    @Test func wrongViewModelNameFails() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: WrongViewModelSchema.self, in: document)
        #expect(error.issues.count == 1)
        guard case .viewModelNotFound(let name, let available) = error.issues[0] else {
            Issue.record("Expected viewModelNotFound, got \(error.issues[0])")
            return
        }
        #expect(name == "DoesNotExist")
        #expect(Set(available) == ["Default", "Nested", "Test"])
    }

    nonisolated struct WrongPathSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let missing = RiveKey<Double>("Missing")
    }

    @Test func wrongPathFails() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: WrongPathSchema.self, in: document)
        #expect(error.issues.count == 1)
        guard case .propertyNotFound(let path, let available) = error.issues[0] else {
            Issue.record("Expected propertyNotFound, got \(error.issues[0])")
            return
        }
        #expect(path == "Missing")
        #expect(available.contains("Number"))
        #expect(available.contains("String"))
    }

    nonisolated struct WrongNestedPathSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let bogus = RiveKey<String>("Nested/Bogus/String")
    }

    @Test func wrongIntermediateSegmentFails() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: WrongNestedPathSchema.self, in: document)
        #expect(error.issues.count == 1)
        guard case .propertyNotFound(let path, let available) = error.issues[0] else {
            Issue.record("Expected propertyNotFound, got \(error.issues[0])")
            return
        }
        #expect(path == "Nested/Bogus/String")
        #expect(available.contains("String"))
        #expect(available.contains("DeeperNested"))
    }

    nonisolated struct TypeMismatchSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let number = RiveKey<Bool>("Number")
    }

    @Test func typeMismatchFails() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: TypeMismatchSchema.self, in: document)
        #expect(error.issues == [
            .typeMismatch(path: "Number", expected: "boolean", actual: "number")
        ])
    }

    nonisolated enum BogusEnum: String, RiveEnum {
        case foo = "Foo"
        case qux = "Qux"
    }

    nonisolated struct BogusEnumCaseSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let mode = RiveKey<BogusEnum>("Enum")
    }

    @Test func swiftEnumCaseMissingFromFileFails() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: BogusEnumCaseSchema.self, in: document)
        let hasEnumIssue = error.issues.contains { issue in
            if case .enumCaseNotInFile(let path, let caseName, let availableCases) = issue {
                return path == "Enum" && caseName == "Qux" && Set(availableCases) == ["Foo", "Bar", "Baz"]
            }
            return false
        }
        #expect(hasEnumIssue, "Expected enumCaseNotInFile for 'Qux', got \(error.issues)")
    }

    nonisolated enum PartialEnum: String, RiveEnum {
        case foo = "Foo"
    }

    nonisolated struct PartialEnumSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let mode = RiveKey<PartialEnum>("Enum")
    }

    @Test func fileEnumCaseMissingFromSwiftIsWarningOnly() async throws {
        let document = try await Fixtures.dataBindingDocument()
        // Does not throw…
        try await document.validate(PartialEnumSchema.self)

        // …but the validator reports the warnings.
        let keys = try PartialEnumSchema.discoverKeys()
        let warnings = try await SchemaValidator.validate(keys: keys, viewModelName: "Test", in: document)
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.isWarning })
        let warnedCases = warnings.compactMap { issue -> String? in
            if case .enumCaseNotInSwift(_, let caseName, _) = issue {
                return caseName
            }
            return nil
        }
        #expect(Set(warnedCases) == ["Bar", "Baz"])
    }

    // MARK: - Aggregation

    nonisolated struct ManyProblemsSchema: RiveSchema {
        static var viewModelName: String? { "Test" }
        let missing = RiveKey<Double>("Missing")
        let mismatched = RiveKey<Bool>("Number")
        let mode = RiveKey<BogusEnum>("Enum")
        let valid = RiveKey<String>("String")
    }

    @Test func allIssuesAreAggregatedIntoOneThrow() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: ManyProblemsSchema.self, in: document)

        // Three error-level issues, plus the enumCaseNotInSwift warnings for
        // BogusEnum's missing "Bar"/"Baz" cases riding along in the same throw.
        #expect(error.issues.filter { $0.isWarning == false }.count == 3)
        #expect(error.issues.filter { $0.isWarning }.count == 2)

        func hasIssue(_ predicate: (RiveSchemaError.Issue) -> Bool) -> Bool {
            error.issues.contains(where: predicate)
        }
        #expect(hasIssue { if case .propertyNotFound(let path, _) = $0 { return path == "Missing" } else { return false } })
        #expect(hasIssue { if case .typeMismatch(let path, _, _) = $0 { return path == "Number" } else { return false } })
        #expect(hasIssue { if case .enumCaseNotInFile(_, let caseName, _) = $0 { return caseName == "Qux" } else { return false } })
    }

    // MARK: - Class-hierarchy discovery

    nonisolated class BaseClassSchema: RiveSchema, @unchecked Sendable {
        static var viewModelName: String? { "Test" }
        let number = RiveKey<Double>("Number")
        required init() {}
    }

    nonisolated final class SubclassSchema: BaseClassSchema, @unchecked Sendable {
        let text = RiveKey<String>("String")
    }

    @Test func classSchemaDiscoversInheritedKeys() throws {
        // `Mirror.children` only covers one level of a class hierarchy;
        // discovery must walk `superclassMirror` so inherited keys are not
        // silently dropped (which would trap later in the instance subscript).
        let keys = try SubclassSchema.discoverKeys()
        #expect(Set(keys.map(\.path)) == ["Number", "String"])
    }

    @Test func classSchemaWithInheritedKeysValidates() async throws {
        let document = try await Fixtures.dataBindingDocument()
        try await document.validate(SubclassSchema.self)
    }

    // MARK: - Discovery failures

    nonisolated struct EmptySchema: RiveSchema {}

    @Test func zeroKeySchemaFailsLoudly() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: EmptySchema.self, in: document)
        #expect(error.issues == [.noKeysDiscovered(schema: "EmptySchema")])
    }

    nonisolated struct ComputedKeysSchema: RiveSchema {
        var number: RiveKey<Double> { RiveKey("Number") }
    }

    @Test func computedOnlyKeysFailLoudly() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let error = try await validationError(of: ComputedKeysSchema.self, in: document)
        #expect(error.issues == [.noKeysDiscovered(schema: "ComputedKeysSchema")])
    }

    // MARK: - Corrupt file

    @Test func corruptFileFailsToParse() async throws {
        let data = try Fixtures.data(named: "corrupt")
        await #expect(throws: RiveLoadError.self) {
            _ = try await RiveDocument.load(.data(data, identifier: "fixture.corrupt.riv"))
        }
    }

    // MARK: - Helpers

    private func validationError<S: RiveSchema>(
        of schema: S.Type,
        in document: RiveDocument
    ) async throws -> RiveSchemaError {
        do {
            try await document.validate(schema)
        } catch let error as RiveSchemaError {
            return error
        }
        throw ValidationDidNotFail()
    }

    private struct ValidationDidNotFail: Error {}
}
