import Foundation
internal import RiveRuntime

/// A runtime-discovered description of one data-binding property.
///
/// Produced by ``RiveDocument/dynamicProperties(artboard:viewModel:)`` and
/// ``RiveDynamicInstance/properties``. Nested view models are flattened into
/// forward-slash paths ("card/title"), matching ``RiveKey`` path notation.
public nonisolated struct RiveDynamicProperty: Identifiable, Equatable, Sendable {
    public var id: String { path }

    /// The forward-slash-separated property path inside the root view model.
    public let path: String

    /// The property's kind, as reported by the file's metadata.
    public let kind: RiveDynamicPropertyKind
}

/// The kind of a ``RiveDynamicProperty``.
public nonisolated enum RiveDynamicPropertyKind: Equatable, Sendable {
    case number
    case bool
    case string
    case color
    /// An enum property, with the case names defined in the file.
    case `enum`(cases: [String])
    case trigger
    /// A kind the dynamic API cannot read or write (lists, images, artboards,
    /// unexpanded view models, ...). Carries a human-readable type name for
    /// display; such properties are discovery-only.
    case unsupported(typeName: String)
}

nonisolated extension RiveDynamicPropertyKind {
    /// The matching internal transport kind, or `nil` for ``unsupported(typeName:)``.
    var propertyKind: RivePropertyKind? {
        switch self {
        case .number: return .number
        case .bool: return .boolean
        case .string: return .string
        case .color: return .color
        case .enum: return .enumeration
        case .trigger: return .trigger
        case .unsupported: return nil
        }
    }
}

// MARK: - Discovery

/// Walks a file's view-model metadata and flattens it into
/// ``RiveDynamicProperty`` paths.
@MainActor
enum DynamicPropertyDiscovery {
    /// Maximum nesting depth walked before a nested view model is reported as
    /// ``RiveDynamicPropertyKind/unsupported(typeName:)`` instead of expanded.
    static let maxDepth = 8

    /// Resolves the root view model name: an explicit `viewModel`, or the
    /// default view model of the given (or file-default) artboard.
    ///
    /// Mirrors ``SchemaValidator``'s resolution so dynamic and typed APIs
    /// fail with the same errors for the same inputs.
    static func resolveRootViewModel(
        viewModel: String?,
        artboard: String?,
        in document: RiveDocument
    ) async throws -> String {
        let file = document.file
        let availableViewModels: [String]
        do {
            availableViewModels = try await file.getViewModelNames()
        } catch {
            throw RiveLoadError.parseFailed(description: "Could not read view model names: \(error.localizedDescription)")
        }

        if let viewModel {
            if let artboard, !document.artboardNames.isEmpty, !document.artboardNames.contains(artboard) {
                throw RiveLoadError.artboardNotFound(name: artboard, available: document.artboardNames)
            }
            guard availableViewModels.contains(viewModel) else {
                throw RiveSchemaError(issues: [
                    .viewModelNotFound(name: viewModel, available: availableViewModels)
                ])
            }
            return viewModel
        }

        let runtimeArtboard = try await document.createArtboard(named: artboard)
        do {
            return try await file.getDefaultViewModelInfo(for: runtimeArtboard).viewModelName
        } catch {
            throw RiveSchemaError(issues: [
                .viewModelNotFound(name: "(artboard default)", available: availableViewModels)
            ])
        }
    }

    /// A discovery walk's full result: the flattened properties plus, per
    /// enum-property path, the file's enum type name — which the public
    /// ``RiveDynamicPropertyKind/enum(cases:)`` does not carry but schema
    /// generation needs to name generated Swift enums.
    struct DiscoveredTree {
        var properties: [RiveDynamicProperty] = []
        var enumNamesByPath: [String: String] = [:]
    }

    /// Discovers every property reachable from `rootViewModel`, recursing into
    /// nested view models (depth-first, file order preserved).
    ///
    /// Cyclic view-model references are cut per path branch: a view model
    /// already expanded on the current branch — or one nested deeper than
    /// ``maxDepth`` — is reported as an `unsupported(typeName: "view model")` leaf.
    static func discover(
        rootViewModel: String,
        in document: RiveDocument
    ) async throws -> [RiveDynamicProperty] {
        try await discoverTree(rootViewModel: rootViewModel, in: document).properties
    }

    /// ``discover(rootViewModel:in:)`` plus the per-path enum names.
    static func discoverTree(
        rootViewModel: String,
        in document: RiveDocument
    ) async throws -> DiscoveredTree {
        let file = document.file

        let enumCasesByName: [String: [String]]
        do {
            let enums = try await file.getViewModelEnums()
            enumCasesByName = Dictionary(uniqueKeysWithValues: enums.map { ($0.name, $0.values) })
        } catch {
            throw RiveLoadError.parseFailed(description: "Could not read enums: \(error.localizedDescription)")
        }

        var propertiesByViewModel: [String: [RiveRuntime.ViewModelProperty]] = [:]
        func properties(of viewModel: String) async throws -> [RiveRuntime.ViewModelProperty] {
            if let cached = propertiesByViewModel[viewModel] {
                return cached
            }
            let properties: [RiveRuntime.ViewModelProperty]
            do {
                properties = try await file.getProperties(of: viewModel)
            } catch {
                throw RiveLoadError.parseFailed(description: "Could not read properties of view model '\(viewModel)': \(error.localizedDescription)")
            }
            propertiesByViewModel[viewModel] = properties
            return properties
        }

        var discovered = DiscoveredTree()
        func walk(viewModel: String, prefix: String, visited: [String], depth: Int) async throws {
            for property in try await properties(of: viewModel) {
                let path = prefix.isEmpty ? property.name : "\(prefix)/\(property.name)"
                switch property.type {
                case .number:
                    discovered.properties.append(RiveDynamicProperty(path: path, kind: .number))
                case .boolean:
                    discovered.properties.append(RiveDynamicProperty(path: path, kind: .bool))
                case .string:
                    discovered.properties.append(RiveDynamicProperty(path: path, kind: .string))
                case .color:
                    discovered.properties.append(RiveDynamicProperty(path: path, kind: .color))
                case .enum:
                    // The enum's type name is reported in `metaData`.
                    discovered.properties.append(RiveDynamicProperty(
                        path: path,
                        kind: .enum(cases: enumCasesByName[property.metaData] ?? [])
                    ))
                    discovered.enumNamesByPath[path] = property.metaData
                case .trigger:
                    discovered.properties.append(RiveDynamicProperty(path: path, kind: .trigger))
                case .viewModel:
                    // The nested view model's name is reported in `metaData`.
                    let nested = property.metaData
                    guard depth < maxDepth, nested.isEmpty == false, visited.contains(nested) == false else {
                        discovered.properties.append(RiveDynamicProperty(path: path, kind: .unsupported(typeName: "view model")))
                        continue
                    }
                    try await walk(
                        viewModel: nested,
                        prefix: path,
                        visited: visited + [nested],
                        depth: depth + 1
                    )
                default:
                    discovered.properties.append(RiveDynamicProperty(
                        path: path,
                        kind: .unsupported(typeName: SchemaValidator.describe(property.type))
                    ))
                }
            }
        }
        try await walk(viewModel: rootViewModel, prefix: "", visited: [rootViewModel], depth: 0)
        return discovered
    }
}
