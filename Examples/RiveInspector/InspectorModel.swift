import SwiftUI
import SwiftyRive
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Which axes the natural-size demo leaves for the artboard to decide.
enum NaturalAxisMode: String, CaseIterable {
    /// Neither axis proposed — the view takes the authored artboard size.
    case both = "Both"
    /// Width pinned to 240 pt — height follows from the artboard's aspect ratio.
    case widthFixed = "Width-fixed"
}

/// Where the currently open document's bytes came from.
enum OpenedSource: Hashable {
    case local(URL)
    case remote(URL)

    var url: URL {
        switch self {
        case .local(let url), .remote(let url): url
        }
    }
}

/// Session state for the whole app: the open document, its dynamic instance,
/// the view options, and the recents list. Owned by `ContentView` and shared
/// by every screen so the split and stack layouts stay interchangeable.
@Observable
final class InspectorModel {
    let recents = RecentsStore()

    private(set) var document: RiveDocument?
    private(set) var openedSource: OpenedSource?
    private(set) var instance: RiveDynamicInstance?
    private(set) var bindingNote: String?
    private(set) var isLoading = false
    private(set) var didCopySchema = false

    var artboard: String?
    var fit: RiveFit = .contain
    var isPaused = false
    var useNaturalSize = false
    var naturalAxisMode: NaturalAxisMode = .both
    var errorMessage: String?
    var isImporterPresented = false
    var isURLPromptPresented = false

    var displayName: String {
        switch openedSource {
        case .local(let url):
            url.lastPathComponent
        case .remote(let url):
            url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case nil:
            "Canvas"
        }
    }

    /// The authored artboard size for the current selection, e.g. "500 × 500 pt".
    var authoredSizeText: String {
        guard let document, let size = try? document.artboardSize(named: artboard) else {
            return "—"
        }
        return Self.sizeText(size)
    }

    // MARK: Opening

    func open(local url: URL) async {
        await load(.local(url), preservingSelection: false)
    }

    func open(remote url: URL) async {
        await load(.remote(url), preservingSelection: false)
    }

    func open(_ entry: RecentEntry) async {
        switch entry.location {
        case .remote(let url):
            await load(.remote(url), preservingSelection: false)
        case .local:
            guard let url = recents.resolveLocalURL(of: entry) else {
                errorMessage = "The file could not be found. It may have been moved or deleted."
                return
            }
            await load(.local(url), preservingSelection: false)
        }
    }

    /// Evicts the document from the shared engine and reloads it from its
    /// source, keeping the selected artboard when it still exists. For the
    /// "designer just re-exported the file" loop; for remote files this
    /// refetches past the engine cache.
    func reload() async {
        guard let openedSource else { return }
        await RiveEngine.shared.removeDocument(for: .url(openedSource.url))
        await load(openedSource, preservingSelection: true)
    }

    /// Ends the session when the user navigates back to Recents.
    func close() {
        document = nil
        instance = nil
        openedSource = nil
        bindingNote = nil
        artboard = nil
        fit = .contain
        isPaused = false
        useNaturalSize = false
        naturalAxisMode = .both
    }

    /// The document is cached, so recreating the dynamic instance on every
    /// artboard switch is cheap.
    func artboardDidChange() async {
        await remakeInstance()
    }

    /// Generates a schema for the selected artboard and puts the source on the
    /// general pasteboard, briefly swapping the icon to a checkmark.
    func copySchemaSource() async {
        guard let document else { return }
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
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Loading

    private func load(_ source: OpenedSource, preservingSelection: Bool) async {
        guard isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        var didAccess = false
        if case .local(let url) = source {
            didAccess = url.startAccessingSecurityScopedResource()
        }
        defer {
            if didAccess, case .local(let url) = source {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let loaded = try await RiveDocument.load(.url(source.url))
            document = loaded
            openedSource = source
            if let current = artboard,
                preservingSelection == false || loaded.artboardNames.contains(current) == false {
                artboard = nil
            }
            await remakeInstance()
            record(source, document: loaded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remakeInstance() async {
        guard let document else { return }
        do {
            instance = try await document.makeDynamicInstance(artboard: artboard)
            bindingNote = nil
        } catch {
            instance = nil
            bindingNote = "No data bindings for this artboard — rendering without controls."
        }
    }

    private func record(_ source: OpenedSource, document: RiveDocument) {
        let size = (try? document.artboardSize()).map(Self.sizeText)
        switch source {
        case .local(let url):
            recents.recordLocal(url, authoredSize: size)
        case .remote(let url):
            recents.recordRemote(url, authoredSize: size)
        }
    }

    private static func sizeText(_ size: CGSize) -> String {
        let format = FloatingPointFormatStyle<Double>.number
            .grouping(.never)
            .precision(.fractionLength(0...1))
        return "\(Double(size.width).formatted(format)) × \(Double(size.height).formatted(format)) pt"
    }
}
