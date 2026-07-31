import SwiftUI
import SwiftyRive
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Everything the generated-source sheet needs, so it is presented from a
/// payload rather than a bare `Bool` — the sheet can never open without a
/// document to generate from.
struct SchemaSourceRequest: Identifiable {
    let id = UUID()
    let document: RiveDocument
    let artboard: String?
}

/// Modal preview of the Swift source `generateSchemaSource(artboard:)` produces
/// for the selected artboard: syntax-highlighted, selectable, scrollable in
/// both axes, with the system share sheet standing in for a bespoke copy
/// button. Generation failures render inline instead of surfacing an alert.
struct SchemaSourceSheet: View {
    let request: SchemaSourceRequest

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    #if os(iOS)
    @State private var detent: PresentationDetent = .large
    #endif

    private enum Phase {
        case loading
        case ready(String)
        case failed(String)
    }

    private var source: String? {
        if case .ready(let source) = phase { return source }
        return nil
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text("Swift Representation")
                .font(.headline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if let source {
                    ShareLink(item: source)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 500)
        .task { await generate() }
        #else
        NavigationStack {
            content
                .navigationTitle("Swift Representation")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let source {
                            ShareLink(item: source)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .task { await generate() }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let source):
            code(source)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Generate Source", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    /// `fixedSize` keeps long lines unwrapped so the horizontal axis actually
    /// scrolls instead of the text reflowing to the sheet's width; the scroll
    /// anchor keeps short sources pinned to the top-left rather than letting a
    /// two-axis `ScrollView` center them.
    private func code(_ source: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(SwiftSourceHighlighter.highlight(source))
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: true, vertical: true)
                .padding(16)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.codeBackground, in: .rect(cornerRadius: 10))
    }

    private static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private func generate() async {
        guard case .loading = phase else { return }
        do {
            phase = .ready(try await request.document.generateSchemaSource(artboard: request.artboard))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Just enough Swift lexing to colorize generated schema source — comments,
/// string literals, keywords, capitalized type names, and numbers. Hand-rolled
/// so the demo picks up no third-party dependency; SwiftUI's Markdown
/// `AttributedString` only monospaces fenced code, it does not highlight it.
enum SwiftSourceHighlighter {
    private static let keywords: Set<String> = [
        "any", "as", "async", "await", "case", "catch", "class", "default",
        "else", "enum", "extension", "false", "for", "func", "guard", "if",
        "import", "in", "init", "internal", "is", "let", "nil", "nonisolated",
        "private", "protocol", "public", "return", "self", "some", "static",
        "struct", "switch", "throws", "true", "try", "var", "where", "while",
    ]

    private static let keyword = Color.pink
    private static let literal = Color.red
    private static let comment = Color.secondary
    private static let type = Color.teal
    private static let number = Color.orange

    static func highlight(_ source: String) -> AttributedString {
        var result = AttributedString()
        var index = source.startIndex
        var plainStart = index

        func emit(_ text: Substring, _ color: Color?) {
            guard text.isEmpty == false else { return }
            var run = AttributedString(text)
            run.foregroundColor = color
            result.append(run)
        }

        /// Flushes uncolored characters accumulated since the last token, then
        /// colors `source[index..<end]` and resumes scanning at `end`.
        func take(upTo end: String.Index, as color: Color?) {
            emit(source[plainStart..<index], nil)
            emit(source[index..<end], color)
            index = end
            plainStart = end
        }

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)

            if character == "/", next < source.endIndex, source[next] == "/" {
                take(upTo: source[index...].firstIndex(of: "\n") ?? source.endIndex, as: comment)
            } else if character == "/", next < source.endIndex, source[next] == "*" {
                take(upTo: endOfBlockComment(in: source, from: next), as: comment)
            } else if character == "\"" {
                take(upTo: endOfStringLiteral(in: source, from: index), as: literal)
            } else if character.isLetter || character == "_" {
                let end = scan(source, from: index) { $0.isLetter || $0.isNumber || $0 == "_" }
                let word = source[index..<end]
                let color =
                    if keywords.contains(String(word)) { keyword }
                    else if word.first?.isUppercase == true { type }
                    else { Color?.none }
                take(upTo: end, as: color)
            } else if character.isNumber {
                take(upTo: scan(source, from: index) { $0.isNumber || $0 == "." || $0 == "_" }, as: number)
            } else {
                index = next
            }
        }
        emit(source[plainStart...], nil)
        return result
    }

    private static func scan(
        _ source: String,
        from start: String.Index,
        while predicate: (Character) -> Bool
    ) -> String.Index {
        var end = start
        while end < source.endIndex, predicate(source[end]) {
            end = source.index(after: end)
        }
        return end
    }

    /// Index just past the closing quote, or the end of source for an
    /// unterminated literal. Backslash escapes swallow the next character.
    private static func endOfStringLiteral(in source: String, from start: String.Index) -> String.Index {
        var end = source.index(after: start)
        while end < source.endIndex {
            if source[end] == "\\" {
                end = source.index(end, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
            } else if source[end] == "\"" {
                return source.index(after: end)
            } else {
                end = source.index(after: end)
            }
        }
        return end
    }

    /// Index just past `*/`, or the end of source when unterminated. Nesting is
    /// ignored — generated source never nests block comments.
    private static func endOfBlockComment(in source: String, from star: String.Index) -> String.Index {
        var end = source.index(after: star)
        while end < source.endIndex {
            let next = source.index(after: end)
            if source[end] == "*", next < source.endIndex, source[next] == "/" {
                return source.index(after: next)
            }
            end = next
        }
        return source.endIndex
    }
}
