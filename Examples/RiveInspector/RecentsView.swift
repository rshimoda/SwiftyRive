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

    /// A screenful of tiles is a screenful of glass, so the grid declares one
    /// container and the system renders them in a single pass. Spacing is zero
    /// on purpose: the container is here to batch the effect, not to let
    /// neighbouring tiles melt into each other the way a toolbar's controls do.
    @ViewBuilder
    private var grid: some View {
        ScrollView {
            if #available(iOS 26.0, macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) { tiles }
            } else {
                tiles
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: Self.columns, spacing: 20) {
            ForEach(model.recents.entries) { entry in
                RecentTile(
                    entry: entry,
                    previews: model.previews,
                    isAvailable: unavailableIDs.contains(entry.id) == false,
                    open: { open(entry) },
                    remove: { model.recents.remove(entry) }
                )
            }
        }
        .padding(16)
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

/// One recents tile: a rendered frame of the file filling the tile corner to
/// corner under a sheet of glass, with the file name, a source badge, and when
/// it was added underneath. The whole tile opens the file; unresolvable entries
/// dim and show a warning in place of artwork but stay deletable.
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
    let remove: () -> Void

    @State private var phase = Phase.loading
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// One shape for the crop, the hover tint, and the glass, so the artwork's
    /// edge and the material's edge are the same curve.
    private static let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)

    /// Only the artwork is the button, so the focus ring, the press feedback,
    /// and the context menu's lifted preview all trace the thumbnail rather
    /// than boxing in the caption. Tapping the caption still opens the file.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The system ring is a rounded rectangle of its own choosing, so it
            // is replaced by one drawn on the tile's exact curve.
            Button(action: open) { preview }
                .buttonStyle(TileButtonStyle())
                .focused($isFocused)
                .focusEffectDisabled()
                .overlay {
                    Self.shape
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .opacity(isFocused ? 1 : 0)
                }
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                }
            caption
                .contentShape(.rect)
                .onTapGesture(perform: open)
        }
        .opacity(isAvailable ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .help(helpText)
        .task(id: entry.id) { await loadPreview() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Remove", remove)
    }

    /// The backdrop stays under the artwork for files drawn on transparency;
    /// the hover tint moves above it, since artwork that reaches the edges
    /// would otherwise hide a highlight painted behind it.
    private var preview: some View {
        artwork
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quinary)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay { Self.shape.fill(.quaternary).opacity(isHovering ? 1 : 0) }
            .clipShape(Self.shape)
            .overlay { rim }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// The artwork bleeds to the tile's corners; the loading and failure
    /// stand-ins keep their natural size and sit in the middle.
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
                .scaledToFill()
                .transition(.opacity)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        }
    }

    /// Liquid Glass laid over the finished tile. The material lenses whatever
    /// is behind it, and that backdrop is now the artwork itself, so the
    /// bending lands where glass bends light — around the rim — and the middle
    /// of the picture stays a plain image. The variant has to be `clear`:
    /// `regular` frosts the whole pane and the preview disappears into it.
    ///
    /// The hairline is the glass layer's own content rather than a separate
    /// overlay, which is the one arrangement that survives the material —
    /// clear glass lifts pale pixels to white, so a stroke behind it vanishes
    /// and a file whose artwork is white leaves no tile at all.
    @ViewBuilder
    private var rim: some View {
        let hairline = Self.shape.strokeBorder(.quaternary, lineWidth: 1)
        if #available(iOS 26.0, macOS 26.0, *) {
            hairline
                .glassEffect(.clear, in: Self.shape)
                // Masked to a band along the rim: the material bends the
                // artwork where a lens would, and the middle stays untouched.
                .mask { Self.shape.strokeBorder(lineWidth: 6) }
        } else {
            hairline
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
