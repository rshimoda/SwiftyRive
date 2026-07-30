import Foundation
internal import RiveRuntime

/// Validates a schema's discovered keys against a file's data-binding metadata.
///
/// The validator walks nested "a/b" paths through view-model properties
/// (the runtime reports the nested view model's name in the property's
/// `metaData`), collects **all** error-level issues into one
/// ``RiveSchemaError``, and returns warning-level issues to the caller.
@MainActor
enum SchemaValidator {
    /// Validates `keys` against `document`.
    ///
    /// - Parameter artboardName: The artboard anchoring a `nil`
    ///   `viewModelName` (its default view model becomes the root), or `nil`
    ///   for the file's default artboard. With an explicit `viewModelName` the
    ///   artboard is only checked for existence.
    /// - Returns: Warning-level issues (currently only
    ///   ``RiveSchemaError/Issue/enumCaseNotInSwift(path:caseName:swiftEnum:)``).
    /// - Throws: ``RiveSchemaError`` when error-level issues were found, or
    ///   ``RiveLoadError`` when the file's metadata could not be read at all
    ///   (including ``RiveLoadError/artboardNotFound(name:available:)`` for an
    ///   unknown `artboardName`).
    static func validate(
        keys: [DiscoveredKey],
        viewModelName: String?,
        artboardName: String? = nil,
        in document: RiveDocument
    ) async throws -> [RiveSchemaError.Issue] {
        let file = document.file
        let availableViewModels: [String]
        do {
            availableViewModels = try await file.getViewModelNames()
        } catch {
            throw RiveLoadError.parseFailed(description: "Could not read view model names: \(error.localizedDescription)")
        }

        // Resolve the root view model: an explicit schema name, or the given
        // (or file-default) artboard's default view model.
        let rootViewModel: String
        if let viewModelName {
            // The artboard does not pick the view model here, but an unknown
            // name is still a caller bug worth failing loudly on.
            if let artboardName, !document.artboardNames.isEmpty, !document.artboardNames.contains(artboardName) {
                throw RiveLoadError.artboardNotFound(name: artboardName, available: document.artboardNames)
            }
            guard availableViewModels.contains(viewModelName) else {
                throw RiveSchemaError(issues: [
                    .viewModelNotFound(name: viewModelName, available: availableViewModels)
                ])
            }
            rootViewModel = viewModelName
        } else {
            let artboard = try await document.createArtboard(named: artboardName)
            do {
                rootViewModel = try await file.getDefaultViewModelInfo(for: artboard).viewModelName
            } catch {
                throw RiveSchemaError(issues: [
                    .viewModelNotFound(name: "(artboard default)", available: availableViewModels)
                ])
            }
        }

        var propertiesByViewModel: [String: [RiveRuntime.ViewModelProperty]] = [:]
        var enumsByName: [String: RiveRuntime.ViewModelEnum]?

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

        func fileEnum(named name: String) async throws -> RiveRuntime.ViewModelEnum? {
            if enumsByName == nil {
                do {
                    let enums = try await file.getViewModelEnums()
                    enumsByName = Dictionary(uniqueKeysWithValues: enums.map { ($0.name, $0) })
                } catch {
                    throw RiveLoadError.parseFailed(description: "Could not read enums: \(error.localizedDescription)")
                }
            }
            return enumsByName?[name]
        }

        var errors: [RiveSchemaError.Issue] = []
        var warnings: [RiveSchemaError.Issue] = []

        for key in keys {
            let segments = key.path.split(separator: "/").map(String.init)
            guard segments.isEmpty == false else {
                errors.append(.propertyNotFound(path: key.path, available: []))
                continue
            }

            // Walk intermediate segments through nested view models.
            var currentViewModel = rootViewModel
            var resolvedParent = true
            for segment in segments.dropLast() {
                let available = try await properties(of: currentViewModel)
                guard let property = available.first(where: { $0.name == segment }) else {
                    errors.append(.propertyNotFound(path: key.path, available: available.map(\.name)))
                    resolvedParent = false
                    break
                }
                guard property.type == .viewModel else {
                    errors.append(.typeMismatch(
                        path: key.path,
                        expected: "nested view model at '\(segment)'",
                        actual: describe(property.type)
                    ))
                    resolvedParent = false
                    break
                }
                // For viewModel-type properties the runtime reports the nested
                // view model's name in `metaData`.
                guard availableViewModels.contains(property.metaData) else {
                    errors.append(.viewModelNotFound(name: property.metaData, available: availableViewModels))
                    resolvedParent = false
                    break
                }
                currentViewModel = property.metaData
            }
            guard resolvedParent, let lastSegment = segments.last else { continue }

            let available = try await properties(of: currentViewModel)
            guard let property = available.first(where: { $0.name == lastSegment }) else {
                errors.append(.propertyNotFound(path: key.path, available: available.map(\.name)))
                continue
            }

            let expectedKind = key.declaration.kind
            guard runtimeType(for: expectedKind) == property.type else {
                errors.append(.typeMismatch(
                    path: key.path,
                    expected: expectedKind.displayName,
                    actual: describe(property.type)
                ))
                continue
            }

            // For enum keys, compare Swift and file case sets. The enum's type
            // name is reported in the property's `metaData`.
            if case .value(.enumeration, let enumTypeName, let enumCases) = key.declaration,
               let enumCases {
                guard let fileEnum = try await fileEnum(named: property.metaData) else {
                    errors.append(.propertyNotFound(path: key.path, available: available.map(\.name)))
                    continue
                }
                for caseName in enumCases where fileEnum.values.contains(caseName) == false {
                    errors.append(.enumCaseNotInFile(
                        path: key.path,
                        caseName: caseName,
                        availableCases: fileEnum.values
                    ))
                }
                for caseName in fileEnum.values where enumCases.contains(caseName) == false {
                    warnings.append(.enumCaseNotInSwift(
                        path: key.path,
                        caseName: caseName,
                        swiftEnum: enumTypeName ?? "(unknown)"
                    ))
                }
            }
        }

        for warning in warnings {
            Log.schema.warning("\(warning.description, privacy: .public)")
        }
        guard errors.isEmpty else {
            throw RiveSchemaError(issues: errors + warnings)
        }
        return warnings
    }

    // MARK: - Runtime type mapping

    private static func runtimeType(for kind: RivePropertyKind) -> RiveRuntime.ViewModelProperty.DataType {
        switch kind {
        case .number: return .number
        case .boolean: return .boolean
        case .string: return .string
        case .color: return .color
        case .enumeration: return .enum
        case .trigger: return .trigger
        }
    }

    /// Human-readable name of a runtime property type, for error messages.
    static func describe(_ type: RiveRuntime.ViewModelProperty.DataType) -> String {
        switch type {
        case .none: return "none"
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .color: return "color"
        case .list: return "list"
        case .enum: return "enum"
        case .trigger: return "trigger"
        case .viewModel: return "view model"
        case .integer: return "integer"
        case .symbolListIndex: return "symbol list index"
        case .assetImage: return "image"
        case .assetFont: return "font"
        case .artboard: return "artboard"
        case .input: return "input"
        case .any: return "any"
        @unknown default: return "unknown"
        }
    }
}
