import Foundation
internal import RiveRuntime

/// Debug helpers for inspecting a file's data-binding metadata.
public enum RiveDiagnostics {
    /// Renders the file's full data-binding tree — view models with their
    /// instances and typed properties, plus all enum definitions — as a
    /// multi-line string, and logs it.
    ///
    /// Useful to discover which paths exist before writing a ``RiveSchema``:
    ///
    /// ```
    /// View models:
    /// - Test (instances: Default, Editor Defaults)
    ///     Number: number
    ///     Nested: view model → Nested
    ///     Enum: enum → Colors
    /// Enums:
    /// - Colors: Foo | Bar | Baz
    /// ```
    ///
    /// Read failures are embedded in the output instead of thrown, so the dump
    /// always produces something usable.
    public static func dumpViewModels(of document: RiveDocument) async -> String {
        let file = document.file
        var lines: [String] = []

        let viewModelNames: [String]
        do {
            viewModelNames = try await file.getViewModelNames()
        } catch {
            let message = "Could not read view model names: \(error.localizedDescription)"
            Log.schema.error("\(message, privacy: .public)")
            return message
        }

        lines.append("View models:")
        if viewModelNames.isEmpty {
            lines.append("- (none)")
        }
        for name in viewModelNames {
            let instanceNames = (try? await file.getInstanceNames(of: name)) ?? []
            let instanceSuffix = instanceNames.isEmpty
                ? ""
                : " (instances: \(instanceNames.map { $0.isEmpty ? "(unnamed)" : $0 }.joined(separator: ", ")))"
            lines.append("- \(name)\(instanceSuffix)")

            do {
                for property in try await file.getProperties(of: name) {
                    var line = "    \(property.name): \(SchemaValidator.describe(property.type))"
                    if property.metaData.isEmpty == false {
                        line += " → \(property.metaData)"
                    }
                    lines.append(line)
                }
            } catch {
                lines.append("    (could not read properties: \(error.localizedDescription))")
            }
        }

        lines.append("Enums:")
        do {
            let enums = try await file.getViewModelEnums()
            if enums.isEmpty {
                lines.append("- (none)")
            }
            for viewModelEnum in enums {
                lines.append("- \(viewModelEnum.name): \(viewModelEnum.values.joined(separator: " | "))")
            }
        } catch {
            lines.append("- (could not read enums: \(error.localizedDescription))")
        }

        let dump = lines.joined(separator: "\n")
        Log.schema.info("Data-binding tree for \(document.source.debugName, privacy: .public):\n\(dump, privacy: .public)")
        return dump
    }
}
