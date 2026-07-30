import SwiftUI

/// The loading phase of an ``AsyncRiveView``.
public enum AsyncRivePhase {
    /// The document is still loading.
    case loading
    /// The document loaded; the associated ``RiveView`` renders it.
    case success(RiveView)
    /// Loading failed.
    case failure(any Error)
}

/// Loads a Rive document from a ``RiveSource`` and renders it, `AsyncImage`-style.
///
/// ```swift
/// AsyncRiveView(source: .bundle("robot")) { phase in
///     switch phase {
///     case .loading: ProgressView()
///     case .success(let rive): rive
///     case .failure: Image(systemName: "exclamationmark.triangle")
///     }
/// }
/// ```
///
/// Documents load through ``RiveEngine/shared``, so repeated appearances of the
/// same source reuse the cached parse.
public struct AsyncRiveView<Content: View>: View {
    private let source: RiveSource
    private let artboardName: String?
    private let stateMachineName: String?
    private let content: (AsyncRivePhase) -> Content

    @State private var phase: AsyncRivePhase = .loading

    /// The load that produced the current terminal phase. On reappearance the
    /// task re-fires with an unchanged ``LoadID``; a matching successful phase
    /// is kept as-is instead of flashing the placeholder and reloading.
    @State private var phaseID: LoadID?

    /// Creates a view that loads `source` and hands the current ``AsyncRivePhase`` to `content`.
    ///
    /// - Parameters:
    ///   - source: Where the `.riv` bytes come from.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    ///   - content: Builds the view for each loading phase.
    public init(
        source: RiveSource,
        artboard: String? = nil,
        stateMachine: String? = nil,
        @ViewBuilder content: @escaping (AsyncRivePhase) -> Content
    ) {
        self.source = source
        self.artboardName = artboard
        self.stateMachineName = stateMachine
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: loadID) {
                let id = loadID
                if case .success = phase, phaseID == id {
                    // Reappearance with the same source: keep the rendered
                    // view instead of flashing the placeholder. (A failure is
                    // not kept — reappearing retries the load.)
                    return
                }
                if case .loading = phase {} else {
                    phase = .loading
                }
                do {
                    let document = try await RiveEngine.shared.document(for: source)
                    // A load superseded mid-await must not resume later and
                    // clobber the newer source's phase.
                    try Task.checkCancellation()
                    phase = .success(
                        RiveView(document, artboard: artboardName, stateMachine: stateMachineName)
                    )
                    phaseID = id
                } catch is CancellationError {
                    // View disappeared or the source changed mid-load.
                } catch {
                    phase = .failure(error)
                    phaseID = id
                }
            }
    }

    private var loadID: LoadID {
        LoadID(source: source, artboard: artboardName, stateMachine: stateMachineName)
    }
}

/// Identity of the current load request, used as the `.task(id:)` trigger.
private nonisolated struct LoadID: Hashable {
    let source: RiveSource
    let artboard: String?
    let stateMachine: String?
}
