import Foundation

/// A Swift value type that can back a Rive view-model property.
///
/// This protocol is closed: the only supported conformances are the ones the
/// package provides — `Double` (number), `Bool` (boolean), `String` (string),
/// ``RiveColor`` (color), and any ``RiveEnum`` (enum). Conforming your own
/// types is unsupported and fails schema validation with
/// ``RiveSchemaError/Issue/unsupportedValueType(label:typeName:)``.
public nonisolated protocol RivePropertyValue: Equatable, Sendable {}

/// A Swift enum mirroring an enum defined in a Rive file.
///
/// Raw values must match the case names in the Rive editor exactly:
///
/// ```swift
/// enum Mood: String, RiveEnum { case idle, happy, alarmed }
/// ```
///
/// Validation compares both directions: Swift cases missing from the file are
/// errors; file cases missing from Swift are logged warnings (reading such a
/// value keeps the last known Swift case).
public nonisolated protocol RiveEnum: RivePropertyValue, RawRepresentable, CaseIterable, Sendable
where RawValue == String {}

extension Double: RivePropertyValue {}
extension Bool: RivePropertyValue {}
extension String: RivePropertyValue {}

nonisolated extension RiveEnum {
    /// All raw values, in declaration order.
    static var allRawValues: [String] {
        allCases.map(\.rawValue)
    }
}

/// The property kinds the typed schema supports, matching the runtime's
/// view-model property metadata.
///
/// The runtime exposes more data types (lists, images, artboards, nested view
/// models, ...); only the value-like kinds below are representable as
/// ``RiveKey`` / ``RiveTriggerKey``.
nonisolated enum RivePropertyKind: Equatable, Sendable {
    case number
    case boolean
    case string
    case color
    case enumeration
    case trigger

    /// Human-readable name used in validation error messages.
    var displayName: String {
        switch self {
        case .number: return "number"
        case .boolean: return "boolean"
        case .string: return "string"
        case .color: return "color"
        case .enumeration: return "enum"
        case .trigger: return "trigger"
        }
    }
}
