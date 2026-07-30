import SwiftUI
import SwiftyRive
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Which axes the natural-size demo leaves for the artboard to decide.
enum NaturalAxisMode: String, CaseIterable {
    /// Neither axis proposed — the view takes the authored artboard size.
    case both = "Both"
    /// Width pinned to 240 pt — height follows from the artboard's aspect ratio.
    case widthFixed = "Width-fixed"
}

/// Sidebar = artboards, detail = canvas, trailing inspector = properties.
/// Files arrive via drag & drop, the file importer, or a launch argument
/// (`swift run RiveInspector path/to/file.riv`).
struct ContentView: View {
    @State private var document: RiveDocument?
    @State private var sourceURL: URL?
    @State private var instance: RiveDynamicInstance?
    @State private var artboard: String?
    @State private var fit: RiveFit = .contain
    @State private var isPaused = false
    @State private var useNaturalSize = false
    @State private var naturalAxisMode: NaturalAxisMode = .both
    @State private var errorText: String?
    @State private var bindingNote: String?
    @State private var isImporterPresented = false
    @State private var isInspectorPresented = true
    @State private var didCopySchema = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            detail
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
    }

    // MARK: Columns

    private var sidebar: some View {
        Group {
            if let document {
                List(selection: $artboard) {
                    Section("Artboards") {
                        Text("Default").tag(String?.none)
                        ForEach(document.artboardNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No File", systemImage: "doc")
                } description: {
                    Text("Open a .riv file to list its artboards.")
                } actions: {
                    Button("Open…") { isImporterPresented = true }
                }
            }
        }
        .navigationTitle("RiveInspector")
    }

    private var detail: some View {
        Group {
            if let document {
                canvas(for: document)
            } else {
                emptyState
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            if let document {
                InspectorPanel(
                    document: document,
                    instance: instance,
                    artboard: artboard,
                    fit: fit,
                    useNaturalSize: $useNaturalSize,
                    naturalAxisMode: $naturalAxisMode,
                    bindingNote: bindingNote
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle(sourceURL?.lastPathComponent ?? "Canvas")
        .onChange(of: artboard) {
            if let document {
                Task { await remakeInstance(for: document) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Reload", systemImage: "arrow.clockwise", action: reload)
                .keyboardShortcut("r")
                .disabled(sourceURL == nil)
                .help("Reload the file from disk")
            Button(
                "Copy Swift Schema",
                systemImage: didCopySchema ? "checkmark" : "doc.on.doc"
            ) {
                if let document { copySchemaSource(of: document) }
            }
            .disabled(document == nil)
            .help("Copy a generated RiveSchema for this file to the clipboard")
            Button("Inspector", systemImage: "sidebar.trailing") {
                isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Show or hide the inspector")
        }
    }

    // MARK: Canvas

    private func canvas(for document: RiveDocument) -> some View {
        VStack(spacing: 0) {
            Group {
                if useNaturalSize {
                    naturalSizePane(for: document)
                } else {
                    riveView(for: document)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottom) {
                playbackControls
                    .padding(.bottom, 16)
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
    }

    /// The shared Rive view, bound to the dynamic instance when one exists,
    /// with the current fit and pause state applied.
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

    /// Floating play/pause + fit controls over the canvas: Liquid Glass on
    /// OS 26, a plain material capsule before that.
    @ViewBuilder
    private var playbackControls: some View {
        let bar = HStack(spacing: 4) {
            Button {
                isPaused.toggle()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .help(isPaused ? "Play" : "Pause")
            Menu {
                Picker("Fit", selection: $fit) {
                    Text("Contain").tag(RiveFit.contain)
                    Text("Cover").tag(RiveFit.cover)
                    Text("Fill").tag(RiveFit.fill)
                    Text("Fit Width").tag(RiveFit.fitWidth)
                    Text("Scale Down").tag(RiveFit.scaleDown)
                    Text("Actual Size").tag(RiveFit.actualSize)
                }
            } label: {
                Image(systemName: "aspectratio")
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .menuIndicator(.hidden)
            .help("Fit")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(4)
        if #available(iOS 26.0, macOS 26.0, *) {
            bar.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            bar.background(.regularMaterial, in: .capsule)
        }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Drop a .riv File", systemImage: "arrow.down.doc")
            } description: {
                Text("Drag a file anywhere in the window, or open one.")
            } actions: {
                Button("Open…") { isImporterPresented = true }
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
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

    // MARK: Loading

    private func load(_ url: URL, preservingSelection: Bool = false) {
        Task {
            errorText = nil
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let loaded = try await RiveDocument.load(.url(url))
                document = loaded
                sourceURL = url
                if let current = artboard,
                    preservingSelection == false || loaded.artboardNames.contains(current) == false {
                    artboard = nil
                }
                await remakeInstance(for: loaded)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// Evicts the document from the shared engine and reloads it from disk,
    /// keeping the selected artboard when it still exists. For the "designer
    /// just re-exported the file" loop.
    private func reload() {
        guard let url = sourceURL else { return }
        Task {
            await RiveEngine.shared.removeDocument(for: .url(url))
            load(url, preservingSelection: true)
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

    /// Generates a schema for the selected artboard and puts the source on the
    /// general pasteboard, briefly swapping the icon to a checkmark.
    private func copySchemaSource(of document: RiveDocument) {
        Task {
            do {
                let source = try await document.generateSchemaSource(artboard: artboard)
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                #else
                UIPasteboard.general.string = source
                #endif
                didCopySchema = true
                try? await Task.sleep(for: .seconds(1.5))
                didCopySchema = false
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
