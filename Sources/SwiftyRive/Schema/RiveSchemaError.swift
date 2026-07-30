import Foundation

/// Aggregated schema-validation failure.
///
/// Validation collects **all** problems before throwing, so one round trip
/// surfaces every mismatch between a ``RiveSchema`` and the file. Warning-level
/// issues (``Issue/enumCaseNotInFile(path:caseName:availableCases:)`` is an
/// error; ``Issue/enumCaseNotInSwift(path:caseName:swiftEnum:)`` is the
/// warning) are logged but never cause a throw on their own.
public nonisolated struct RiveSchemaError: Error {
    /// One concrete mismatch between the schema and the file.
    public enum Issue: Equatable, Sendable {
        /// The schema's view model does not exist in the file.
        case viewModelNotFound(name: String, available: [String])
        /// A key's path does not resolve to a property.
        case propertyNotFound(path: String, available: [String])
        /// A key's path resolves to a property of a different type.
        case typeMismatch(path: String, expected: String, actual: String)
        /// A Swift enum case has no counterpart in the file's enum.
        case enumCaseNotInFile(path: String, caseName: String, availableCases: [String])
        /// A file enum case has no counterpart in the Swift enum (warning-level:
        /// logged, but does not fail validation).
        case enumCaseNotInSwift(path: String, caseName: String, swiftEnum: String)
        /// The schema declared no keys `Mirror` could discover.
        case noKeysDiscovered(schema: String)
        /// A key's `Value` type is not a supported ``RivePropertyValue``.
        case unsupportedValueType(label: String, typeName: String)

        /// True for issues that are reported but do not fail validation.
        public var isWarning: Bool {
            if case .enumCaseNotInSwift = self {
                return true
            }
            return false
        }
    }

    /// Every issue found, in discovery order.
    public let issues: [Issue]

    /// Creates an error wrapping the given issues.
    public init(issues: [Issue]) {
        self.issues = issues
    }
}

nonisolated extension RiveSchemaError.Issue: CustomStringConvertible {
    /// A human-readable, actionable description of the mismatch.
    public var description: String {
        switch self {
        case .viewModelNotFound(let name, let available):
            if available.isEmpty {
                return "View model '\(name)' was not found; the file defines no view models."
            }
            return "View model '\(name)' was not found. Available view models: \(available.joined(separator: ", "))."
        case .propertyNotFound(let path, let available):
            if available.isEmpty {
                return "Property '\(path)' was not found; the enclosing view model has no properties."
            }
            return "Property '\(path)' was not found. Available properties at that level: \(available.joined(separator: ", "))."
        case .typeMismatch(let path, let expected, let actual):
            return "Property '\(path)' is declared as \(expected) in the schema but is \(actual) in the file."
        case .enumCaseNotInFile(let path, let caseName, let availableCases):
            return "Enum case '\(caseName)' for property '\(path)' does not exist in the file. Cases in the file: \(availableCases.joined(separator: ", "))."
        case .enumCaseNotInSwift(let path, let caseName, let swiftEnum):
            return "File enum case '\(caseName)' for property '\(path)' has no counterpart in Swift enum \(swiftEnum) (warning)."
        case .noKeysDiscovered(let schema):
            return "Schema \(schema) declares no discoverable keys. Keys must be stored properties (computed properties are invisible to Mirror)."
        case .unsupportedValueType(let label, let typeName):
            return "Key '\(label)' has unsupported value type \(typeName). Supported types: Double, Bool, String, RiveColor, and RiveEnum conformances."
        }
    }
}

nonisolated extension RiveSchemaError: CustomStringConvertible {
    /// A multi-line summary listing every issue found.
    public var description: String {
        let lines = issues.map { "- \($0.description)" }
        return "Schema validation found \(issues.count) issue(s):\n" + lines.joined(separator: "\n")
    }
}

nonisolated extension RiveSchemaError: LocalizedError {
    /// The same multi-line summary as ``description``.
    public var errorDescription: String? {
        description
    }
}
