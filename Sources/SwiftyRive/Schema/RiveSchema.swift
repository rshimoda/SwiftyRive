import Foundation

/// A typed description of a Rive view model.
///
/// Declare each property as a stored ``RiveKey`` / ``RiveTriggerKey``:
///
/// ```swift
/// enum Mood: String, RiveEnum { case idle, happy, alarmed }
///
/// struct RobotSchema: RiveSchema {
///     let energy = RiveKey<Double>("energy")
///     let tint = RiveKey<RiveColor>("tint")
///     let mood = RiveKey<Mood>("mood")
///     let celebrate = RiveTriggerKey("celebrate")
/// }
/// ```
///
/// Keys are discovered via `Mirror`, so they must be **stored** properties —
/// computed keys are invisible and a schema with zero discoverable keys fails
/// loudly. Validate against a file with ``RiveDocument/validate(_:artboard:)`` or bind
/// with ``RiveDocument/makeInstance(of:artboard:)``.
public nonisolated protocol RiveSchema: Sendable {
    init()

    /// The view model name in the file, or `nil` to bind against an
    /// artboard's default view model.
    ///
    /// With `nil`, ``RiveDocument/makeInstance(of:artboard:)`` and
    /// ``RiveDocument/validate(_:artboard:)`` resolve the default view model
    /// of the artboard passed to them — or of the **file's default artboard**
    /// when none is passed. The binding is anchored to that artboard's view
    /// model: rendering the instance with a *different* artboard whose default
    /// view model differs will not work (writes succeed but change nothing on
    /// screen). Either name the view model explicitly here, or pass the same
    /// artboard to `makeInstance(of:artboard:)` that you render with.
    static var viewModelName: String? { get }
}

nonisolated extension RiveSchema {
    /// Defaults to `nil`: bind against the given (or file-default) artboard's
    /// default view model. See ``viewModelName`` for the artboard-anchoring
    /// caveat.
    public static var viewModelName: String? { nil }
}

// MARK: - Key discovery

/// A schema key found by reflection: the Swift property label plus the
/// runtime path and declared property shape.
nonisolated struct DiscoveredKey: Equatable, Sendable {
    let label: String
    let path: String
    let declaration: DeclaredProperty
}

nonisolated extension RiveSchema {
    /// Enumerates the schema's stored keys via `Mirror`.
    ///
    /// - Throws: ``RiveSchemaError`` when the schema declares no keys at all
    ///   (usually because keys were written as computed properties) or when a
    ///   key's `Value` type is not one of the supported conformances.
    static func discoverKeys() throws -> [DiscoveredKey] {
        var keys: [DiscoveredKey] = []
        var issues: [RiveSchemaError.Issue] = []

        // Walk the whole superclass chain: a `Mirror`'s `children` cover only
        // the properties declared at that level, so a class-hierarchy schema
        // would otherwise silently drop inherited keys (and later trap on the
        // instance subscript).
        var mirror: Mirror? = Mirror(reflecting: Self())
        while let current = mirror {
            for child in current.children {
                guard let key = child.value as? any AnySchemaKey else { continue }
                let label = child.label ?? key.path
                guard let declaration = key.declaration else {
                    issues.append(.unsupportedValueType(
                        label: label,
                        typeName: String(describing: type(of: child.value))
                    ))
                    continue
                }
                keys.append(DiscoveredKey(label: label, path: key.path, declaration: declaration))
            }
            mirror = current.superclassMirror
        }

        if keys.isEmpty && issues.isEmpty {
            issues.append(.noKeysDiscovered(schema: String(describing: Self.self)))
        }
        guard issues.isEmpty else {
            throw RiveSchemaError(issues: issues)
        }
        return keys
    }
}
