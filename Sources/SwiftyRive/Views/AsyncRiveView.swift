import SwiftUI

/// The loading phase of an ``AsyncRiveView``.
public enum RivePhase {
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
    private let content: (RivePhase) -> Content

    @State private var phase: RivePhase = .loading

    /// Creates a view that loads `source` and hands the current ``RivePhase`` to `content`.
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
        @ViewBuilder content: @escaping (RivePhase) -> Content
    ) {
        self.source = source
        self.artboardName = artboard
        self.stateMachineName = stateMachine
        self.content = content
    }

    public var body: some View {
        content(phase)
            .task(id: loadID) {
                if case .success = phase {
                    phase = .loading
                } else if case .failure = phase {
                    phase = .loading
                }
                do {
                    let document = try await RiveEngine.shared.document(for: source)
                    phase = .success(
                        RiveView(document, artboard: artboardName, stateMachine: stateMachineName)
                    )
                } catch is CancellationError {
                    // View disappeared or the source changed mid-load.
                } catch {
                    phase = .failure(error)
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
