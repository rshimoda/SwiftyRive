import Foundation
import Observation
internal import RiveRuntime

/// One observable cell of an instance's local mirror.
///
/// Instances keep their mirror as an `@ObservationIgnored` dictionary of
/// slots (the key set is fixed at creation, so the dictionary itself never
/// needs tracking) and route all reads/writes through `box`. That makes
/// observation per-key: a view reading one property re-renders only when
/// *that* property changes, not on every animating property each frame.
@Observable
@MainActor
final class MirrorSlot {
    var box: PropertyBox

    init(_ box: PropertyBox) {
        self.box = box
    }
}

/// A type-erased property value held in a ``RiveInstance``'s local mirror.
///
/// One small enum replaces per-type mirror storage: the generic subscript
/// converts between `V: RivePropertyValue` and a box in one place, so no
/// per-type class copies are needed.
nonisolated enum PropertyBox: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case color(RiveColor)
    case enumCase(String)

    /// Boxes a supported value; `nil` for unsupported `RivePropertyValue`
    /// conformances (which schema discovery already rejects).
    init?<V: RivePropertyValue>(_ value: V) {
        switch value {
        case let number as Double:
            self = .number(number)
        case let boolean as Bool:
            self = .boolean(boolean)
        case let string as String:
            self = .string(string)
        case let color as RiveColor:
            self = .color(color)
        default:
            guard let riveEnum = value as? any RiveEnum else {
                return nil
            }
            self = .enumCase(riveEnum.rawValue)
        }
    }

    /// The property kind this box carries a value for.
    var kind: RivePropertyKind {
        switch self {
        case .number: return .number
        case .boolean: return .boolean
        case .string: return .string
        case .color: return .color
        case .enumCase: return .enumeration
        }
    }

    /// Unboxes as `V`; `nil` on a kind mismatch or an enum raw value that the
    /// Swift enum does not define.
    func value<V: RivePropertyValue>(as type: V.Type) -> V? {
        switch self {
        case .number(let number):
            return number as? V
        case .boolean(let boolean):
            return boolean as? V
        case .string(let string):
            return string as? V
        case .color(let color):
            return color as? V
        case .enumCase(let rawValue):
            guard let enumType = V.self as? any RiveEnum.Type else {
                return nil
            }
            return enumType.init(rawValue: rawValue) as? V
        }
    }
}

// MARK: - Runtime transport

/// Reads and writes boxes through a runtime `ViewModelInstance`.
///
/// All kind-switching lives here so ``RiveInstance`` stays a thin generic shell.
@MainActor
enum PropertyTransport {
    /// Reads the current value at `path` as a box.
    static func readValue(
        of kind: RivePropertyKind,
        at path: String,
        from instance: RiveRuntime.ViewModelInstance
    ) async throws -> PropertyBox {
        do {
            switch kind {
            case .number:
                return .number(Double(try await instance.value(of: NumberProperty(path: path))))
            case .boolean:
                return .boolean(try await instance.value(of: BoolProperty(path: path)))
            case .string:
                return .string(try await instance.value(of: StringProperty(path: path)))
            case .color:
                return .color(RiveColor(runtimeColor: try await instance.value(of: ColorProperty(path: path))))
            case .enumeration:
                return .enumCase(try await instance.value(of: EnumProperty(path: path)))
            case .trigger:
                throw RiveLoadError.propertyReadFailed(path: path, description: "Triggers have no value")
            }
        } catch let error as RiveLoadError {
            throw error
        } catch {
            throw RiveLoadError.propertyReadFailed(path: path, description: error.localizedDescription)
        }
    }

    /// Writes a box to `path`. Synchronous and silent, mirroring the runtime's
    /// `setValue`; safe because paths are proven by schema validation.
    static func write(
        _ box: PropertyBox,
        at path: String,
        to instance: RiveRuntime.ViewModelInstance
    ) {
        switch box {
        case .number(let number):
            instance.setValue(of: NumberProperty(path: path), to: Float(number))
        case .boolean(let boolean):
            instance.setValue(of: BoolProperty(path: path), to: boolean)
        case .string(let string):
            instance.setValue(of: StringProperty(path: path), to: string)
        case .color(let color):
            instance.setValue(of: ColorProperty(path: path), to: color.runtimeColor)
        case .enumCase(let rawValue):
            instance.setValue(of: EnumProperty(path: path), to: rawValue)
        }
    }

    /// Starts a task consuming the runtime's value stream for `path`,
    /// forwarding each change to `onValue` (on the main actor).
    static func observeValues(
        of kind: RivePropertyKind,
        at path: String,
        from instance: RiveRuntime.ViewModelInstance,
        onValue: @escaping @MainActor (PropertyBox) -> Void
    ) -> Task<Void, Never>? {
        switch kind {
        case .number:
            return consume(instance.valueStream(of: NumberProperty(path: path)), at: path) {
                onValue(.number(Double($0)))
            }
        case .boolean:
            return consume(instance.valueStream(of: BoolProperty(path: path)), at: path) {
                onValue(.boolean($0))
            }
        case .string:
            return consume(instance.valueStream(of: StringProperty(path: path)), at: path) {
                onValue(.string($0))
            }
        case .color:
            return consume(instance.valueStream(of: ColorProperty(path: path)), at: path) {
                onValue(.color(RiveColor(runtimeColor: $0)))
            }
        case .enumeration:
            return consume(instance.valueStream(of: EnumProperty(path: path)), at: path) {
                onValue(.enumCase($0))
            }
        case .trigger:
            return nil
        }
    }

    private static func consume<Element: Sendable>(
        _ stream: AsyncThrowingStream<Element, any Error>,
        at path: String,
        forwarding forward: @escaping @MainActor (Element) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                for try await element in stream {
                    if Task.isCancelled { break }
                    forward(element)
                }
            } catch {
                Log.binding.error("Value stream for '\(path, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
