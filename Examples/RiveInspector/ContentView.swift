#if os(macOS)
import AppKit
import SwiftUI
import SwiftyRive
import UniformTypeIdentifiers

/// Which axes the natural-size demo leaves for the artboard to decide.
enum NaturalAxisMode: String, CaseIterable {
    /// Neither axis proposed — the view takes the authored artboard size.
    case both = "Both"
    /// Width pinned to 240 pt — height follows from the artboard's aspect ratio.
    case widthFixed = "Width-fixed"
}

/// Empty (drop hint) → loaded. Files arrive via drag & drop, the open panel,
/// or a launch argument (`swift run RiveInspector path/to/file.riv`).
struct ContentView: View {
    @State private var document: RiveDocument?
    @State private var instance: RiveDynamicInstance?
    @State private var artboard: String?
    @State private var fit: RiveFit = .contain
    @State private var isPaused = false
    @State private var useNaturalSize = false
    @State private var naturalAxisMode: NaturalAxisMode = .both
    @State private var errorText: String?
    @State private var bindingNote: String?
    @State private var isImporterPresented = false
    @State private var didCopySchema = false

    var body: some View {
        Group {
            if let document {
                HSplitView {
                    mainPane(for: document)
                    InspectorPanel(
                        document: document,
                        instance: instance,
                        artboard: $artboard,
                        fit: $fit,
                        isPaused: $isPaused,
                        useNaturalSize: $useNaturalSize,
                        naturalAxisMode: $naturalAxisMode,
                        bindingNote: bindingNote
                    )
                }
            } else {
                emptyState
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "riv" }) else { return false }
            load(url)
            return true
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "riv") ?? .data]
        ) { result in
            if case .success(let url) = result {
                load(url)
            }
        }
        .task {
            if CommandLine.arguments.count > 1 {
                load(URL(fileURLWithPath: CommandLine.arguments[1]))
            }
        }
        .toolbar {
            if let document {
                ToolbarItem {
                    Button {
                        copySchemaSource(of: document)
                    } label: {
                        Label(
                            "Copy Swift Schema",
                            systemImage: didCopySchema ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .help("Copy a generated RiveSchema for this file to the clipboard")
                }
            }
        }
    }

    /// Generates a schema for the selected artboard and puts the source on the
    /// general pasteboard, briefly swapping the icon to a checkmark.
    private func copySchemaSource(of document: RiveDocument) {
        Task {
            do {
                let source = try await document.generateSchemaSource(artboard: artboard)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                didCopySchema = true
                try? await Task.sleep(for: .seconds(1.5))
                didCopySchema = false
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop a .riv file here")
                .font(.title3)
            Button("Open…") { isImporterPresented = true }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mainPane(for document: RiveDocument) -> some View {
        VStack(spacing: 0) {
            Group {
                if useNaturalSize {
                    naturalSizePane(for: document)
                } else {
                    riveView(for: document)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(minWidth: 400)
        .layoutPriority(1)
        .onChange(of: artboard) {
            Task { await remakeInstance(for: document) }
        }
    }

    /// The shared Rive view, bound to the dynamic instance when one exists,
    /// with the sidebar's fit and pause state applied.
    private func riveView(for document: RiveDocument) -> some View {
        Group {
            if let instance {
                RiveView(instance, artboard: artboard)
            } else {
                RiveView(document, artboard: artboard)
            }
        }
        .riveFit(fit)
        .rivePaused(isPaused)
    }

    /// Natural-size demo over a checkerboard, with a border marking the view's
    /// actual bounds. Each mode uses `fixedSize` to un-propose the axes it
    /// wants the artboard to decide.
    private func naturalSizePane(for document: RiveDocument) -> some View {
        ZStack {
            CheckerboardBackground()
            Group {
                switch naturalAxisMode {
                case .both:
                    riveView(for: document)
                        .riveNaturalSize()
                        .fixedSize()
                case .widthFixed:
                    riveView(for: document)
                        .riveNaturalSize()
                        .frame(width: 240)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .border(Color.accentColor, width: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func load(_ url: URL) {
        Task {
            errorText = nil
            do {
                let loaded = try await RiveDocument.load(.url(url))
                document = loaded
                artboard = nil
                await remakeInstance(for: loaded)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// Subtle alternating squares that make the Rive view's edges legible in
    /// natural-size mode without competing with the artboard's own colors.
    private struct CheckerboardBackground: View {
        var body: some View {
            Canvas { context, size in
                let cell: CGFloat = 12
                for row in 0..<Int((size.height / cell).rounded(.up)) {
                    for column in 0..<Int((size.width / cell).rounded(.up))
                    where (row + column).isMultiple(of: 2) {
                        let square = CGRect(
                            x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell
                        )
                        context.fill(Path(square), with: .color(.primary.opacity(0.06)))
                    }
                }
            }
        }
    }

    /// The document is cached, so recreating the dynamic instance on every
    /// artboard switch is cheap.
    private func remakeInstance(for document: RiveDocument) async {
        do {
            instance = try await document.makeDynamicInstance(artboard: artboard)
            bindingNote = nil
        } catch {
            instance = nil
            bindingNote = "No data bindings for this artboard — rendering without controls."
        }
    }
}
#endif
