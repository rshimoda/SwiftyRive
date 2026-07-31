import SwiftUI

/// Root of the detail stack: previously opened files, newest first. Rows
/// swipe-to-delete (context menu on macOS, where swiping is awkward) and dim
/// when a local file can no longer be resolved.
struct RecentsView: View {
    let model: InspectorModel

    @State private var unavailableIDs: Set<RecentEntry.ID> = []

    var body: some View {
        Group {
            if model.recents.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Recents")
        .toolbar {
            ToolbarItemGroup {
                Button("Open File…", systemImage: "folder") {
                    model.isImporterPresented = true
                }
                .keyboardShortcut("o")
                .help("Open a .riv file from disk")
                Button("Open URL…", systemImage: "link") {
                    model.isURLPromptPresented = true
                }
                .keyboardShortcut("O")
                .help("Load a .riv file from the web")
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

    private var list: some View {
        List {
            ForEach(model.recents.entries) { entry in
                RecentRow(entry: entry, isAvailable: !unavailableIDs.contains(entry.id)) {
                    open(entry)
                }
                .contextMenu {
                    Button("Remove from Recents", systemImage: "trash", role: .destructive) {
                        model.recents.remove(entry)
                    }
                }
            }
            .onDelete { model.recents.remove(atOffsets: $0) }
        }
    }

    /// The action-carrying empty state for the whole detail area.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recent Files", systemImage: "clock")
        } description: {
            #if os(macOS)
            Text("Drop a .riv file anywhere in the window, or open one from disk or a URL.")
            #else
            Text("Open a .riv file from disk, or load one from a URL. Dropped files open too.")
            #endif
        } actions: {
            Button("Open File…") { model.isImporterPresented = true }
                .buttonStyle(.borderedProminent)
            Button("Open URL…") { model.isURLPromptPresented = true }
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

/// One recents row: file name, authored-size subtitle, and a Local/Remote
/// source badge. Unresolvable entries render dimmed with an error subtitle but
/// stay deletable.
private struct RecentRow: View {
    let entry: RecentEntry
    let isAvailable: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .foregroundStyle(isAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(entry.isRemote ? "Remote" : "Local")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .opacity(isAvailable ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var iconName: String {
        if isAvailable == false { return "exclamationmark.triangle" }
        return entry.isRemote ? "globe" : "doc"
    }

    private var subtitle: String? {
        if isAvailable == false { return "File not found" }
        return entry.authoredSize
    }

    private var helpText: String {
        switch entry.location {
        case .local(let path, _): path
        case .remote(let url): url.absoluteString
        }
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
