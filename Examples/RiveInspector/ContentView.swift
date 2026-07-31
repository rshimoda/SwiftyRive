import SwiftUI
import SwiftyRive
import UniformTypeIdentifiers

/// Screens pushed onto the detail stack.
enum InspectorRoute: Hashable {
    case file
}

/// Navigation shell. Regular widths (macOS, iPad): `NavigationSplitView` with
/// the controls sidebar leading and a `NavigationStack` (Recents → file
/// screen) in the detail column. Compact widths (iPhone): the same stack alone,
/// with the controls reachable as a sheet from the file screen's toolbar.
///
/// Files arrive via drag & drop, the file importer, a URL prompt, a recents
/// row, or a launch argument (`swift run RiveInspector path/to/file.riv`) —
/// every successful open records a recents entry and pushes the file screen.
struct ContentView: View {
    @State private var model = InspectorModel()
    @State private var path: [InspectorRoute] = []
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        layout
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "riv" }) else {
                    return false
                }
                Task { await model.open(local: url) }
                return true
            }
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [UTType(filenameExtension: "riv") ?? .data]
            ) { result in
                if case .success(let url) = result {
                    Task { await model.open(local: url) }
                }
            }
            .sheet(isPresented: $model.isURLPromptPresented) {
                OpenURLSheet { url in
                    Task { await model.open(remote: url) }
                }
            }
            .alert("Couldn't Load File", isPresented: isErrorPresented) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onChange(of: documentIdentity) {
                // Any successful open (drop, importer, URL, recents row,
                // launch argument) lands on the file screen.
                if model.document != nil, path.isEmpty {
                    path = [.file]
                }
            }
            .onChange(of: path) {
                // Standard back navigation closes the session, returning the
                // sidebar to its neutral empty state.
                if path.isEmpty {
                    model.close()
                }
            }
            .task {
                if let argument = Self.launchFileArgument {
                    await model.open(local: URL(fileURLWithPath: argument))
                }
            }
    }

    // MARK: Layout

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            detailStack
        } else {
            splitLayout
        }
        #else
        splitLayout
        #endif
    }

    private var splitLayout: some View {
        NavigationSplitView {
            SidebarPanel(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
                .navigationTitle("RiveInspector")
        } detail: {
            detailStack
        }
    }

    private var detailStack: some View {
        NavigationStack(path: $path) {
            RecentsView(model: model)
                .navigationDestination(for: InspectorRoute.self) { route in
                    switch route {
                    case .file:
                        FileScreen(model: model)
                    }
                }
        }
    }

    // MARK: Helpers

    private var documentIdentity: ObjectIdentifier? {
        model.document.map(ObjectIdentifier.init)
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if $0 == false { model.errorMessage = nil } }
        )
    }

    /// First `.riv` launch argument, e.g. `swift run RiveInspector file.riv`.
    /// Extension-matched so the arguments Xcode and the simulator inject are
    /// never mistaken for a file to open.
    private static var launchFileArgument: String? {
        CommandLine.arguments.dropFirst().first {
            $0.hasPrefix("-") == false && $0.lowercased().hasSuffix(".riv")
        }
    }
}

/// The canvas screen for the open document. All controls live in the top
/// toolbar and the leading sidebar — nothing floats over the canvas.
struct FileScreen: View {
    let model: InspectorModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isControlsPresented = false
    #endif

    var body: some View {
        Group {
            if let document = model.document {
                canvas(for: document)
            } else {
                // Transient while the session closes on the way back.
                Color.clear
            }
        }
        .navigationTitle(model.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .onChange(of: model.artboard) {
            Task { await model.artboardDidChange() }
        }
        #if os(iOS)
        .sheet(isPresented: $isControlsPresented) {
            NavigationStack {
                SidebarPanel(model: model)
                    .navigationTitle("Controls")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isControlsPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(
                model.isPaused ? "Play" : "Pause",
                systemImage: model.isPaused ? "play.fill" : "pause.fill"
            ) {
                model.isPaused.toggle()
            }
            .help(model.isPaused ? "Play" : "Pause")
            Button("Reload", systemImage: "arrow.clockwise") {
                Task { await model.reload() }
            }
            .keyboardShortcut("r")
            .help("Reload the file from its source")
            Button(
                "Copy Swift Schema",
                systemImage: model.didCopySchema ? "checkmark" : "doc.on.doc"
            ) {
                Task { await model.copySchemaSource() }
            }
            .help("Copy a generated RiveSchema for this file to the clipboard")
        }
        #if os(iOS)
        if horizontalSizeClass == .compact {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Controls", systemImage: "slider.horizontal.3") {
                    isControlsPresented = true
                }
                .help("Show the artboard, view, and property controls")
            }
        }
        #endif
    }

    // MARK: Canvas

    private func canvas(for document: RiveDocument) -> some View {
        Group {
            if model.useNaturalSize {
                naturalSizePane(for: document)
            } else {
                riveView(for: document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The shared Rive view, bound to the dynamic instance when one exists,
    /// with the current fit and pause state applied.
    private func riveView(for document: RiveDocument) -> some View {
        Group {
            if let instance = model.instance {
                RiveView(instance, artboard: model.artboard)
            } else {
                RiveView(document, artboard: model.artboard)
            }
        }
        .riveFit(model.fit)
        .rivePaused(model.isPaused)
    }

    /// Natural-size demo over a checkerboard, with a border marking the view's
    /// actual bounds. Each mode uses `fixedSize` to un-propose the axes it
    /// wants the artboard to decide.
    private func naturalSizePane(for document: RiveDocument) -> some View {
        ZStack {
            CheckerboardBackground()
            Group {
                switch model.naturalAxisMode {
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
}
