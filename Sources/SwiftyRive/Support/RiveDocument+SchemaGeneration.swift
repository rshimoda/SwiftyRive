import Foundation

extension RiveDocument {
    /// Generates compilable Swift source for a ``RiveSchema`` matching the
    /// file's data-binding properties.
    ///
    /// The output declares one `RiveEnum` per file enum used, then a schema
    /// struct with one key per supported property, in file discovery order:
    ///
    /// ```swift
    /// nonisolated enum Colors: String, RiveEnum {
    ///     case foo = "Foo"
    ///     case bar = "Bar"
    /// }
    ///
    /// nonisolated struct GeneratedSchema: RiveSchema {
    ///     let number = RiveKey<Double>("Number")
    ///     let mode = RiveKey<Colors>("Enum")
    ///     let nestedString = RiveKey<String>("Nested/String")
    /// }
    /// ```
    ///
    /// Swift names are derived from the last path segment (lower-camel-cased,
    /// sanitized to valid identifiers, de-duplicated deterministically via the
    /// parent segment and then a numeric suffix). Properties the typed API
    /// cannot represent (lists, images, ...) are listed in a trailing comment
    /// block instead of as keys. Every declaration is emitted `nonisolated` so
    /// the source compiles unchanged both in ordinary modules and in modules
    /// built with `defaultIsolation(MainActor.self)`.
    ///
    /// Paste the result into a project that imports SwiftyRive, then check it
    /// against the file with ``validate(_:artboard:)``.
    ///
    /// - Parameters:
    ///   - typeName: The name of the generated schema struct, sanitized into a
    ///     valid Swift identifier.
    ///   - artboard: The artboard whose default view model anchors a `nil`
    ///     `viewModel`, or `nil` for the file's default artboard. Ignored when
    ///     `viewModel` is given (beyond checking that the artboard exists).
    ///   - viewModel: An explicit view model name, or `nil` to use the
    ///     artboard's default view model. When given, the generated struct
    ///     pins ``RiveSchema/viewModelName`` to it.
    /// - Returns: Swift source for the schema, ending in a newline.
    /// - Throws: The same errors as ``dynamicProperties(artboard:viewModel:)``.
    public func generateSchemaSource(
        named typeName: String = "GeneratedSchema",
        artboard: String? = nil,
        viewModel: String? = nil
    ) async throws -> String {
        let rootViewModel = try await DynamicPropertyDiscovery.resolveRootViewModel(
            viewModel: viewModel,
            artboard: artboard,
            in: self
        )
        let tree = try await DynamicPropertyDiscovery.discoverTree(rootViewModel: rootViewModel, in: self)
        return SchemaSourceGenerator.source(
            typeName: typeName,
            properties: tree.properties,
            enumNamesByPath: tree.enumNamesByPath,
            artboard: artboard,
            viewModel: viewModel
        )
    }
}

// MARK: - Generation

/// Pure string building over discovered properties. Deterministic: identical
/// inputs always produce identical source.
nonisolated enum SchemaSourceGenerator {
    /// Renders the full schema source (header, enum declarations, struct).
    static func source(
        typeName: String,
        properties: [RiveDynamicProperty],
        enumNamesByPath: [String: String],
        artboard: String?,
        viewModel: String?
    ) -> String {
        var typePool = SchemaSourceNaming.NamePool()
        let structName = typePool.claim([
            SchemaSourceNaming.upperCamelIdentifier(from: typeName, fallback: "GeneratedSchema")
        ])

        // File enums in order of first use, one Swift declaration each.
        var swiftEnumNamesByPath: [String: String] = [:]
        var swiftEnumNamesByFileEnum: [String: String] = [:]
        var enumDeclarations: [String] = []
        for property in properties {
            guard case .enum(let cases) = property.kind, cases.isEmpty == false else { continue }
            let fileEnumName = enumNamesByPath[property.path] ?? ""
            let identity = fileEnumName.isEmpty ? "path:\(property.path)" : fileEnumName
            if let existing = swiftEnumNamesByFileEnum[identity] {
                swiftEnumNamesByPath[property.path] = existing
                continue
            }
            let nameSource = fileEnumName.isEmpty ? lastSegment(of: property.path) : fileEnumName
            let swiftName = typePool.claim([
                SchemaSourceNaming.upperCamelIdentifier(from: nameSource, fallback: "GeneratedEnum")
            ])
            swiftEnumNamesByFileEnum[identity] = swiftName
            swiftEnumNamesByPath[property.path] = swiftName
            enumDeclarations.append(enumDeclaration(named: swiftName, cases: cases))
        }

        // One key per supported property, plus a trailing comment per
        // unsupported one.
        var keyPool = SchemaSourceNaming.NamePool()
        var keyLines: [String] = []
        var unsupportedLines: [String] = []
        for property in properties {
            let keyType: String
            switch property.kind {
            case .number:
                keyType = "RiveKey<Double>"
            case .bool:
                keyType = "RiveKey<Bool>"
            case .string:
                keyType = "RiveKey<String>"
            case .color:
                keyType = "RiveKey<RiveColor>"
            case .enum:
                guard let enumName = swiftEnumNamesByPath[property.path] else {
                    unsupportedLines.append("// unsupported (enum with no cases): \(property.path)")
                    continue
                }
                keyType = "RiveKey<\(enumName)>"
            case .trigger:
                keyType = "RiveTriggerKey"
            case .unsupported(let typeName):
                unsupportedLines.append("// unsupported (\(typeName)): \(property.path)")
                continue
            }

            let last = lastSegment(of: property.path)
            var candidates = [SchemaSourceNaming.lowerCamelIdentifier(from: last)]
            if let parent = parentSegment(of: property.path) {
                candidates.append(SchemaSourceNaming.lowerCamelIdentifier(from: "\(parent) \(last)"))
            }
            let name = keyPool.claim(candidates)
            keyLines.append(
                "let \(SchemaSourceNaming.escaped(name)) = \(keyType)(\(SchemaSourceNaming.stringLiteral(property.path)))"
            )
        }

        // Assembly.
        let origin = artboard.map { "artboard \(SchemaSourceNaming.stringLiteral($0))" } ?? "the default artboard"
        var blocks = ["// Generated by SwiftyRive from \(origin). Verify with document.validate(_:artboard:)."]
        blocks.append(contentsOf: enumDeclarations)

        var bodyBlocks: [[String]] = []
        if let viewModel {
            bodyBlocks.append(["static var viewModelName: String? { \(SchemaSourceNaming.stringLiteral(viewModel)) }"])
        }
        if keyLines.isEmpty == false {
            bodyBlocks.append(keyLines)
        }
        if unsupportedLines.isEmpty == false {
            bodyBlocks.append(unsupportedLines)
        }
        let body = bodyBlocks
            .map { $0.map { "    \($0)" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        var structDeclaration = "nonisolated struct \(structName): RiveSchema {"
        if body.isEmpty == false {
            structDeclaration += "\n\(body)\n"
        }
        structDeclaration += "}"
        blocks.append(structDeclaration)

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Renders one `nonisolated enum <Name>: String, RiveEnum` declaration.
    /// Raw values are spelled out whenever the Swift case name differs from
    /// the file's case string.
    private static func enumDeclaration(named name: String, cases: [String]) -> String {
        var lines = ["nonisolated enum \(name): String, RiveEnum {"]
        var pool = SchemaSourceNaming.NamePool()
        for rawCase in cases {
            let caseName = pool.claim([SchemaSourceNaming.lowerCamelIdentifier(from: rawCase, fallback: "value")])
            if caseName == rawCase {
                lines.append("    case \(SchemaSourceNaming.escaped(caseName))")
            } else {
                lines.append("    case \(SchemaSourceNaming.escaped(caseName)) = \(SchemaSourceNaming.stringLiteral(rawCase))")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func lastSegment(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func parentSegment(of path: String) -> String? {
        let segments = path.split(separator: "/")
        guard segments.count >= 2 else { return nil }
        return String(segments[segments.count - 2])
    }
}

// MARK: - Naming

/// Turns arbitrary Rive names (property paths, enum names, case strings) into
/// valid Swift identifiers. Internal for direct unit testing.
nonisolated enum SchemaSourceNaming {
    /// A lower-camel-case identifier ("Trigger Red" → "triggerRed"), or
    /// `fallback` when nothing identifier-like survives sanitization.
    static func lowerCamelIdentifier(from raw: String, fallback: String = "property") -> String {
        identifier(from: raw, capitalizingFirstWord: false, fallback: fallback)
    }

    /// An upper-camel-case identifier ("item selection" → "ItemSelection"), or
    /// `fallback` when nothing identifier-like survives sanitization.
    static func upperCamelIdentifier(from raw: String, fallback: String = "Value") -> String {
        identifier(from: raw, capitalizingFirstWord: true, fallback: fallback)
    }

    private static func identifier(from raw: String, capitalizingFirstWord: Bool, fallback: String) -> String {
        let words = raw.split { !$0.isLetter && !$0.isNumber }
        guard let first = words.first else { return fallback }

        var name = capitalizingFirstWord
            ? first.prefix(1).uppercased() + first.dropFirst()
            : first.prefix(1).lowercased() + first.dropFirst()
        for word in words.dropFirst() {
            name += word.prefix(1).uppercased() + word.dropFirst()
        }
        if name.first?.isNumber == true {
            name = "_" + name
        }
        return name
    }

    /// Backtick-escapes reserved words so they are usable as member names.
    static func escaped(_ identifier: String) -> String {
        reservedWords.contains(identifier) ? "`\(identifier)`" : identifier
    }

    /// Renders `value` as a Swift string literal, escaping special characters.
    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\0": escaped += "\\0"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Claims the first unused candidate, falling back to numeric suffixes on
    /// the last one ("string", "nestedString", "nestedString2", ...).
    struct NamePool {
        private var used: Set<String> = []

        mutating func claim(_ candidates: [String]) -> String {
            for candidate in candidates where used.contains(candidate) == false {
                used.insert(candidate)
                return candidate
            }
            let base = candidates.last ?? "property"
            var suffix = 2
            while used.contains("\(base)\(suffix)") {
                suffix += 1
            }
            let name = "\(base)\(suffix)"
            used.insert(name)
            return name
        }
    }

    /// Swift reserved words that need backticks in declaration position.
    private static let reservedWords: Set<String> = [
        "Any", "Self", "as", "associatedtype", "await", "borrowing", "break",
        "case", "catch", "class", "consuming", "continue", "default", "defer",
        "deinit", "do", "else", "enum", "extension", "fallthrough", "false",
        "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
        "inout", "internal", "is", "let", "nil", "operator", "precedencegroup",
        "private", "protocol", "public", "repeat", "rethrows", "return",
        "self", "static", "struct", "subscript", "super", "switch", "throw",
        "throws", "true", "try", "typealias", "var", "where", "while",
    ]
}
