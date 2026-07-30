import Foundation
import Observation
internal import RiveRuntime

/// A live, observable two-way binding over a view model instance whose
/// properties were **discovered at runtime** instead of declared in a
/// ``RiveSchema``.
///
/// This is the deliberately dynamic and lenient counterpart of
/// ``RiveInstance``: paths are strings, every accessor is optional, and a
/// wrong path or kind returns `nil` (and logs) instead of trapping. Use it for
/// tooling and inspection — for application code, prefer a typed schema, which
/// proves every path at load time.
///
/// Create instances with ``RiveDocument/makeDynamicInstance(artboard:viewModel:)``
/// and render them with ``RiveView/init(_:artboard:stateMachine:)-(RiveDynamicInstance,_,_)``.
/// Reads are synchronous from a local mirror seeded with the file's initial
/// values; writes update the mirror, forward to the runtime, and nudge the
/// attached view (workaround for rive-ios #383). Changes originating inside
/// the animation flow back through per-path value streams, so SwiftUI
/// observation sees both directions.
@MainActor
@Observable
public final class RiveDynamicInstance {
    /// Every property discovered on the bound view model, flattened across
    /// nested view models. Fixed at creation.
    public let properties: [RiveDynamicProperty]

    /// The document the instance was created from (held strongly — the
    /// runtime requires the file to outlive the view model instance).
    let document: RiveDocument

    /// The bound runtime instance (held strongly for the runtime's sake).
    let viewModelInstance: RiveRuntime.ViewModelInstance

    /// Local mirror of every supported value property, keyed by path.
    private var mirror: [String: PropertyBox] = [:]

    /// The transport kind of every supported property, keyed by path.
    @ObservationIgnored
    private let kindsByPath: [String: RivePropertyKind]

    /// The file-defined cases of every enum property, keyed by path.
    @ObservationIgnored
    private let enumCasesByPath: [String: [String]]

    /// One stream-consumption task per value path. Cancelled on deinit.
    @ObservationIgnored
    private var observationTasks: [Task<Void, Never>] = []

    /// The render host of the view currently displaying this instance — see
    /// ``RiveInstance/renderHost``.
    @ObservationIgnored
    weak var renderHost: RiveRenderHost?

    /// Creates an instance over `viewModelInstance`, seeding the mirror with
    /// the current value of every supported property.
    init(
        properties: [RiveDynamicProperty],
        viewModelInstance: RiveRuntime.ViewModelInstance,
        document: RiveDocument
    ) async throws {
        self.properties = properties
        self.document = document
        self.viewModelInstance = viewModelInstance

        var kinds: [String: RivePropertyKind] = [:]
        var enumCases: [String: [String]] = [:]
        var seeded: [String: PropertyBox] = [:]
        for property in properties {
            guard let kind = property.kind.propertyKind else { continue }
            kinds[property.path] = kind
            if case .enum(let cases) = property.kind {
                enumCases[property.path] = cases
            }
            guard kind != .trigger else { continue }
            seeded[property.path] = try await PropertyTransport.readValue(
                of: kind,
                at: property.path,
                from: viewModelInstance
            )
        }
        kindsByPath = kinds
        enumCasesByPath = enumCases
        mirror = seeded

        observationTasks = properties.compactMap { property in
            guard let kind = property.kind.propertyKind else { return nil }
            return PropertyTransport.observeValues(
                of: kind,
                at: property.path,
                from: viewModelInstance
            ) { [weak self] box in
                self?.applyRemoteChange(box, at: property.path)
            }
        }
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
    }

    // MARK: - Values

    /// The number at `path`, or `nil` when the path is unknown or not a
    /// number. Setting `nil` — or setting through a wrong path/kind — is a
    /// logged no-op.
    public subscript(number path: String) -> Double? {
        get { read(path, expecting: .number)?.value(as: Double.self) }
        set { write(newValue.map(PropertyBox.number), at: path) }
    }

    /// The boolean at `path`, or `nil` when the path is unknown or not a
    /// boolean. Setting `nil` — or setting through a wrong path/kind — is a
    /// logged no-op.
    public subscript(bool path: String) -> Bool? {
        get { read(path, expecting: .boolean)?.value(as: Bool.self) }
        set { write(newValue.map(PropertyBox.boolean), at: path) }
    }

    /// The string at `path`, or `nil` when the path is unknown or not a
    /// string. Setting `nil` — or setting through a wrong path/kind — is a
    /// logged no-op.
    public subscript(string path: String) -> String? {
        get { read(path, expecting: .string)?.value(as: String.self) }
        set { write(newValue.map(PropertyBox.string), at: path) }
    }

    /// The color at `path`, or `nil` when the path is unknown or not a color.
    /// Setting `nil` — or setting through a wrong path/kind — is a logged
    /// no-op.
    public subscript(color path: String) -> RiveColor? {
        get { read(path, expecting: .color)?.value(as: RiveColor.self) }
        set { write(newValue.map(PropertyBox.color), at: path) }
    }

    /// The current case name of the enum at `path`, or `nil` when the path is
    /// unknown or not an enum. Setting `nil`, a case name the file does not
    /// define, or setting through a wrong path/kind is a logged no-op.
    public subscript(enumValue path: String) -> String? {
        get {
            guard case .enumCase(let rawValue)? = read(path, expecting: .enumeration) else { return nil }
            return rawValue
        }
        set {
            guard let newValue else { return }
            guard let cases = enumCasesByPath[path], cases.contains(newValue) else {
                Log.binding.error("Ignoring write of unknown enum case '\(newValue, privacy: .public)' at '\(path, privacy: .public)' (cases: \(self.enumCasesByPath[path]?.joined(separator: ", ") ?? "not an enum path", privacy: .public))")
                return
            }
            write(.enumCase(newValue), at: path)
        }
    }

    // MARK: - Triggers

    /// Fires the trigger at `path` and nudges the attached view so any
    /// resulting state transition renders even while paused. Firing a path
    /// that is not a trigger is a logged no-op.
    public func fire(_ path: String) {
        guard kindsByPath[path] == .trigger else {
            Log.binding.error("Ignoring fire at '\(path, privacy: .public)': not a trigger path")
            return
        }
        viewModelInstance.fire(trigger: TriggerProperty(path: path))
        renderHost?.requestAdvanceNudge()
    }

    // MARK: - Private

    /// Returns the mirrored box for `path`, or `nil` (with a log) on an
    /// unknown path or a kind mismatch.
    private func read(_ path: String, expecting kind: RivePropertyKind) -> PropertyBox? {
        guard let box = mirror[path], box.kind == kind else {
            Log.binding.error("No \(kind.displayName, privacy: .public) property at '\(path, privacy: .public)'")
            return nil
        }
        return box
    }

    /// Writes a box to `path` when the path exists with the matching kind;
    /// otherwise a logged no-op. `nil` boxes (a `nil` subscript assignment)
    /// are silently ignored.
    private func write(_ box: PropertyBox?, at path: String) {
        guard let box else { return }
        guard kindsByPath[path] == box.kind else {
            Log.binding.error("Ignoring \(box.kind.displayName, privacy: .public) write at '\(path, privacy: .public)': no such property of that kind")
            return
        }
        guard mirror[path] != box else { return }
        mirror[path] = box
        PropertyTransport.write(box, at: path, to: viewModelInstance)
        renderHost?.requestAdvanceNudge()
    }

    /// Applies a runtime-originated change to the mirror.
    /// The equality guard breaks write/stream echo loops.
    private func applyRemoteChange(_ box: PropertyBox, at path: String) {
        guard mirror[path] != box else { return }
        mirror[path] = box
    }
}

// MARK: - Diagnostics

extension RiveDynamicInstance {
    /// Reads the number at `path` directly from the runtime, bypassing the
    /// local mirror. Diagnostic-only (SPI).
    @_spi(Probe)
    public func probeRuntimeNumber(at path: String) async -> Double? {
        try? await PropertyTransport.readValue(of: .number, at: path, from: viewModelInstance)
            .value(as: Double.self)
    }

    /// Reads the string at `path` directly from the runtime, bypassing the
    /// local mirror. Diagnostic-only (SPI).
    @_spi(Probe)
    public func probeRuntimeString(at path: String) async -> String? {
        try? await PropertyTransport.readValue(of: .string, at: path, from: viewModelInstance)
            .value(as: String.self)
    }

    /// Writes a string at `path` directly to the runtime, bypassing the local
    /// mirror; indistinguishable from a change Rive originates itself.
    /// Diagnostic-only (SPI).
    @_spi(Probe)
    public func probeRuntimeWrite(string value: String, at path: String) {
        PropertyTransport.write(.string(value), at: path, to: viewModelInstance)
    }
}

extension RiveDocument {
    /// Dumps every view model's raw property metadata plus the artboard's
    /// default view model resolution. Diagnostic-only (SPI).
    @_spi(Probe)
    public func probeDumpViewModels(artboard: String? = nil) async -> [String] {
        var lines: [String] = []
        if let names = try? await file.getViewModelNames() {
            for name in names {
                let properties = (try? await file.getProperties(of: name)) ?? []
                let described = properties
                    .map { "\($0.name): \($0.type)\($0.metaData.isEmpty ? "" : " (meta: \($0.metaData))")" }
                    .joined(separator: ", ")
                lines.append("VM '\(name)': [\(described)]")
            }
        }
        if let runtimeArtboard = try? await createArtboard(named: artboard),
           let info = try? await file.getDefaultViewModelInfo(for: runtimeArtboard) {
            lines.append("Default VM of artboard '\(artboard ?? "(default)")': '\(info.viewModelName)', instance: '\(info.instanceName)'")
        } else {
            lines.append("Default VM of artboard '\(artboard ?? "(default)")': unavailable")
        }
        return lines
    }
}

// MARK: - Creation

extension RiveDocument {
    /// Discovers the data-binding properties of a view model and creates a
    /// live ``RiveDynamicInstance`` over a fresh view model instance.
    ///
    /// - Parameters:
    ///   - artboard: The artboard whose default view model anchors a `nil`
    ///     `viewModel`, or `nil` for the file's default artboard. Ignored when
    ///     `viewModel` is given (beyond checking that the artboard exists).
    ///   - viewModel: An explicit view model name, or `nil` to use the
    ///     artboard's default view model.
    /// - Throws: ``RiveLoadError/artboardNotFound(name:available:)`` for an
    ///   unknown artboard, ``RiveSchemaError`` when the view model cannot be
    ///   resolved (e.g. the file has no data bindings), or ``RiveLoadError``
    ///   when metadata cannot be read.
    public func makeDynamicInstance(
        artboard: String? = nil,
        viewModel: String? = nil
    ) async throws -> RiveDynamicInstance {
        let rootViewModel = try await DynamicPropertyDiscovery.resolveRootViewModel(
            viewModel: viewModel,
            artboard: artboard,
            in: self
        )
        let properties = try await DynamicPropertyDiscovery.discover(rootViewModel: rootViewModel, in: self)

        let source: RiveRuntime.ViewModelInstanceSource
        if let viewModel {
            source = .viewModelDefault(from: .name(viewModel))
        } else {
            let runtimeArtboard = try await createArtboard(named: artboard)
            source = .viewModelDefault(from: .artboardDefault(runtimeArtboard))
        }

        let viewModelInstance: RiveRuntime.ViewModelInstance
        do {
            viewModelInstance = try await file.createViewModelInstance(source)
        } catch {
            throw RiveLoadError.parseFailed(description: "Could not create a view model instance: \(error.localizedDescription)")
        }

        return try await RiveDynamicInstance(
            properties: properties,
            viewModelInstance: viewModelInstance,
            document: self
        )
    }

    /// Discovers the data-binding properties of a view model without creating
    /// an instance (metadata reads only).
    ///
    /// - Parameters:
    ///   - artboard: The artboard whose default view model anchors a `nil`
    ///     `viewModel`, or `nil` for the file's default artboard. Ignored when
    ///     `viewModel` is given (beyond checking that the artboard exists).
    ///   - viewModel: An explicit view model name, or `nil` to use the
    ///     artboard's default view model.
    /// - Throws: The same errors as ``makeDynamicInstance(artboard:viewModel:)``.
    public func dynamicProperties(
        artboard: String? = nil,
        viewModel: String? = nil
    ) async throws -> [RiveDynamicProperty] {
        let rootViewModel = try await DynamicPropertyDiscovery.resolveRootViewModel(
            viewModel: viewModel,
            artboard: artboard,
            in: self
        )
        return try await DynamicPropertyDiscovery.discover(rootViewModel: rootViewModel, in: self)
    }
}
