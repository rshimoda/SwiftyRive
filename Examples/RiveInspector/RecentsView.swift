import SwiftUI

/// Root of the detail stack: previously opened files, newest first, as a grid
/// of preview tiles. Each tile renders its own frame through
/// ``RecentPreviewStore``, a context menu removes the entry, and tiles whose
/// file can no longer be resolved dim instead of disappearing.
struct RecentsView: View {
    let model: InspectorModel

    @State private var unavailableIDs: Set<RecentEntry.ID> = []

    /// Two tiles across an iPhone, four on an iPad in portrait, as many as fit
    /// as a Mac window widens — and never one grown past thumbnail size.
    private static let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

    var body: some View {
        Group {
            if model.recents.entries.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("Rive Inspector")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                openAffordance
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task(id: model.recents.entries) { refreshAvailability() }
    }

    /// One "add" affordance for both sources. A `Menu` on every platform: the
    /// system anchors it to the button, and menu items keep their ⌘O / ⇧⌘O
    /// equivalents for hardware keyboards.
    private var openAffordance: some View {
        Menu {
            Button("Open Local File…", systemImage: "folder") {
                model.isImporterPresented = true
            }
            .keyboardShortcut("o")
            Button("Open Link…", systemImage: "link") {
                model.isURLPromptPresented = true
            }
            .keyboardShortcut("O")
        } label: {
            Label("Open", systemImage: "plus")
        }
        .help("Open a .riv file from disk or the web")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(model.recents.entries) { entry in
                    RecentTile(
                        entry: entry,
                        previews: model.previews,
                        isAvailable: unavailableIDs.contains(entry.id) == false
                    ) {
                        open(entry)
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            model.recents.remove(entry)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// The action-carrying empty state for the whole detail area.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recent Files", systemImage: "clock")
        } description: {
            #if os(macOS)
            Text("Drop a .riv file anywhere in the window, or open one from disk or a link.")
            #else
            Text("Open a .riv file from disk, or load one from a link. Dropped files open too.")
            #endif
        } actions: {
            // Same wording as the toolbar's menu, so one action never has two names.
            Button("Open Local File…") { model.isImporterPresented = true }
                .buttonStyle(.borderedProminent)
            Button("Open Link…") { model.isURLPromptPresented = true }
        }
    }

    private func open(_ entry: RecentEntry) {
        guard !unavailableIDs.contains(entry.id) else {
            model.errorMessage = "The file could not be found. It may have been moved or deleted."
            return
        }
        Task { await model.open(entry) }
    }

    private func refreshAvailability() {
        unavailableIDs = Set(
            model.recents.entries
                .filter { model.recents.isAvailable($0) == false }
                .map(\.id)
        )
    }
}

/// One recents tile: a rendered frame of the file over a subtle backdrop, with
/// the file name, a source badge, and when it was added underneath. The whole
/// tile opens the file; unresolvable entries dim and show a warning in place of
/// artwork but stay deletable.
private struct RecentTile: View {
    /// What the preview area shows right now.
    private enum Phase {
        case loading
        case ready(CGImage)
        case unavailable
    }

    let entry: RecentEntry
    let previews: RecentPreviewStore
    let isAvailable: Bool
    let open: () -> Void

    @State private var phase = Phase.loading
    @State private var isHovering = false

    /// Transparent artwork needs a lid: without the border a preview with no
    /// background of its own bleeds into the window.
    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                caption
            }
            .contentShape(.rect)
            .opacity(isAvailable ? 1 : 0.5)
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovering = $0 }
        .help(helpText)
        .task(id: entry.id) { await loadPreview() }
    }

    private var preview: some View {
        artwork
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Self.shape.fill(.quinary)
                    Self.shape.fill(.quaternary).opacity(isHovering ? 1 : 0)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(Self.shape)
            .overlay { Self.shape.strokeBorder(.quaternary, lineWidth: 1) }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var artwork: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .transition(.opacity)
        case .ready(let image):
            Image(decorative: image, scale: 2)
                .resizable()
                .scaledToFit()
                .transition(.opacity)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text(entry.isRemote ? "Link" : "Local")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                if isAvailable {
                    Text(entry.openedAt, format: .relative(presentation: .named))
                } else {
                    Text("File not found")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// Renders on first appearance only: an entry already in the cache shows
    /// its artwork immediately instead of flashing the loading state again.
    private func loadPreview() async {
        if let cached = previews.cachedImage(for: entry) {
            phase = .ready(cached)
            return
        }
        let image = await previews.image(for: entry)
        withAnimation(.easeOut(duration: 0.2)) {
            phase = image.map(Phase.ready) ?? .unavailable
        }
    }

    private var helpText: String {
        switch entry.location {
        case .local(let path, _): path
        case .remote(let url): url.absoluteString
        }
    }
}

/// Press feedback for a whole-tile button: a small, quick shrink, so the tile
/// reacts the way a thumbnail should instead of flashing a system highlight.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Paste-friendly prompt for a remote .riv URL. The engine downloads the bytes
/// and caches the document, so repeat opens are instant.
struct OpenURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onOpen: (URL) -> Void

    @State private var text = ""

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text("Open URL")
                .font(.headline)
            TextField("https://example.com/animation.riv", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(20)
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/animation.riv", text: $text)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                } footer: {
                    Text("The file downloads once and is cached in memory.")
                }
            }
            .navigationTitle("Open URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: submit)
                        .disabled(url == nil)
                }
            }
        }
        .presentationDetents([.medium])
        #endif
    }

    private func submit() {
        guard let url else { return }
        dismiss()
        onOpen(url)
    }
}
