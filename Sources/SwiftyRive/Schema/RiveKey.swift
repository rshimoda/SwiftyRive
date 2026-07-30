import Foundation

/// A typed reference to a value property in a Rive view model.
///
/// The path uses the runtime's forward-slash notation for nested view models
/// ("card/title"). Declare keys as stored properties of a ``RiveSchema``:
///
/// ```swift
/// struct RobotSchema: RiveSchema {
///     let energy = RiveKey<Double>("energy")
///     let tint = RiveKey<RiveColor>("tint")
/// }
/// ```
public nonisolated struct RiveKey<Value: RivePropertyValue>: Hashable, Sendable {
    /// The forward-slash-separated property path inside the view model.
    public let path: String

    /// Creates a key for the property at `path`.
    public init(_ path: String) {
        self.path = path
    }
}

/// A typed reference to a trigger property in a Rive view model.
///
/// Triggers have no value; they are fired via ``RiveInstance/fire(_:)`` and
/// observed via ``RiveInstance/firings(of:)``.
public nonisolated struct RiveTriggerKey: Hashable, Sendable {
    /// The forward-slash-separated property path inside the view model.
    public let path: String

    /// Creates a key for the trigger at `path`.
    public init(_ path: String) {
        self.path = path
    }
}

// MARK: - Internal key erasure

/// What a schema key declares about its property, independent of the generic
/// `Value` parameter. Produced during Mirror-based key discovery.
nonisolated enum DeclaredProperty: Equatable, Sendable {
    /// A value property of the given kind. For enums, carries the Swift enum's
    /// type name and raw values so validation can compare case sets.
    case value(kind: RivePropertyKind, enumTypeName: String?, enumCases: [String]?)
    /// A trigger property.
    case trigger

    var kind: RivePropertyKind {
        switch self {
        case .value(let kind, _, _): return kind
        case .trigger: return .trigger
        }
    }
}

/// Non-generic view of a schema key, used to enumerate keys via `Mirror`.
nonisolated protocol AnySchemaKey {
    var path: String { get }
    /// The declared property, or `nil` when `Value` is not one of the
    /// supported ``RivePropertyValue`` conformances.
    var declaration: DeclaredProperty? { get }
}

extension RiveKey: AnySchemaKey {
    var declaration: DeclaredProperty? {
        if Value.self == Double.self {
            return .value(kind: .number, enumTypeName: nil, enumCases: nil)
        }
        if Value.self == Bool.self {
            return .value(kind: .boolean, enumTypeName: nil, enumCases: nil)
        }
        if Value.self == String.self {
            return .value(kind: .string, enumTypeName: nil, enumCases: nil)
        }
        if Value.self == RiveColor.self {
            return .value(kind: .color, enumTypeName: nil, enumCases: nil)
        }
        if let enumType = Value.self as? any RiveEnum.Type {
            return .value(
                kind: .enumeration,
                enumTypeName: String(describing: Value.self),
                enumCases: enumType.allRawValues
            )
        }
        return nil
    }
}

extension RiveTriggerKey: AnySchemaKey {
    var declaration: DeclaredProperty? { .trigger }
}
