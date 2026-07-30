import Foundation
import Testing
@testable import SwiftyRive

struct ErrorMessageTests {
    @Test func viewModelNotFoundListsAvailableNames() {
        let issue = RiveSchemaError.Issue.viewModelNotFound(name: "Robot", available: ["Test", "Nested"])
        #expect(issue.description.contains("Robot"))
        #expect(issue.description.contains("Test"))
        #expect(issue.description.contains("Nested"))
    }

    @Test func propertyNotFoundListsAvailableProperties() {
        let issue = RiveSchemaError.Issue.propertyNotFound(path: "energy", available: ["Number", "String"])
        #expect(issue.description.contains("energy"))
        #expect(issue.description.contains("Number"))
        #expect(issue.description.contains("String"))
    }

    @Test func typeMismatchNamesBothTypes() {
        let issue = RiveSchemaError.Issue.typeMismatch(path: "Number", expected: "boolean", actual: "number")
        #expect(issue.description.contains("Number"))
        #expect(issue.description.contains("boolean"))
        #expect(issue.description.contains("number"))
    }

    @Test func enumCaseNotInFileListsFileCases() {
        let issue = RiveSchemaError.Issue.enumCaseNotInFile(path: "Enum", caseName: "Qux", availableCases: ["Foo", "Bar"])
        #expect(issue.description.contains("Qux"))
        #expect(issue.description.contains("Foo"))
        #expect(issue.description.contains("Bar"))
        #expect(issue.isWarning == false)
    }

    @Test func enumCaseNotInSwiftIsMarkedAsWarning() {
        let issue = RiveSchemaError.Issue.enumCaseNotInSwift(path: "Enum", caseName: "Baz", swiftEnum: "Mood")
        #expect(issue.description.contains("Baz"))
        #expect(issue.description.contains("Mood"))
        #expect(issue.description.contains("warning"))
        #expect(issue.isWarning)
    }

    @Test func noKeysDiscoveredExplainsStoredPropertyRequirement() {
        let issue = RiveSchemaError.Issue.noKeysDiscovered(schema: "EmptySchema")
        #expect(issue.description.contains("EmptySchema"))
        #expect(issue.description.contains("stored"))
    }

    @Test func unsupportedValueTypeListsSupportedTypes() {
        let issue = RiveSchemaError.Issue.unsupportedValueType(label: "count", typeName: "RiveKey<Int>")
        #expect(issue.description.contains("count"))
        #expect(issue.description.contains("RiveKey<Int>"))
        #expect(issue.description.contains("Double"))
        #expect(issue.description.contains("RiveColor"))
    }

    @Test func aggregatedErrorJoinsAllIssues() {
        let error = RiveSchemaError(issues: [
            .propertyNotFound(path: "a", available: ["b"]),
            .typeMismatch(path: "c", expected: "number", actual: "string"),
        ])
        #expect(error.description.contains("2 issue(s)"))
        #expect(error.description.contains("'a'"))
        #expect(error.description.contains("'c'"))
        #expect(error.errorDescription == error.description)
    }

    @Test func loadErrorMessagesContainHints() {
        let artboard = RiveLoadError.artboardNotFound(name: "Hero", available: ["Main", "Alt"])
        #expect(artboard.localizedDescription.contains("Hero"))
        #expect(artboard.localizedDescription.contains("Main"))

        let property = RiveLoadError.propertyReadFailed(path: "Nested/String", description: "boom")
        #expect(property.localizedDescription.contains("Nested/String"))
        #expect(property.localizedDescription.contains("boom"))
    }
}
