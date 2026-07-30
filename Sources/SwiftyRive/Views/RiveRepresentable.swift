import SwiftUI
internal import RiveRuntime

/// Thin platform representable hosting the runtime's `RiveUIView`.
///
/// Custom (not the runtime's `RiveUIViewRepresentable`) so the package
/// controls the hosted view: needed for `sizeThatFits` and advance-nudge wiring.
struct RiveRepresentable {
    let rive: RiveRuntime.Rive?
    let isPaused: Bool
    let framesPerSecond: Int?
    let host: RiveRenderHost
    let document: RiveDocument
    let artboardName: String?
    let usesNaturalSize: Bool

    /// Retains the render host so dismantling (a static call with no access to
    /// the representable) can still reach ``RiveRenderHost/teardown()``.
    @MainActor
    final class Coordinator {
        let host: RiveRenderHost

        init(host: RiveRenderHost) {
            self.host = host
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host)
    }

    private var frameRate: RiveRuntime.FrameRate {
        framesPerSecond.map { .fps($0) } ?? .default
    }

    private func makeView() -> RiveUIView {
        let view = RiveUIView(rive: rive, isPaused: isPaused)
        host.adoptHostedView(view, desiredIsPaused: isPaused)
        return view
    }

    private func updateView(_ view: RiveUIView) {
        host.adoptHostedView(view, desiredIsPaused: isPaused)
        if view.rive !== rive {
            view.rive = rive
        }
        // Skip pause syncing while an advance-nudge briefly unpauses the view,
        // so an unrelated SwiftUI update does not cut the nudge frame short.
        if view.isPaused != isPaused, host.isNudging == false {
            view.isPaused = isPaused
        }
        if view.frameRate != frameRate {
            view.frameRate = frameRate
        }
    }

    /// The size to report from `sizeThatFits`, or `nil` for the platform's
    /// default (greedy) sizing. Engages only when `.riveNaturalSize()` is set
    /// and the authored size is readable; any failure falls back to greedy.
    private func naturalSize(for proposal: ProposedViewSize) -> CGSize? {
        guard usesNaturalSize,
              let natural = try? document.artboardSize(named: artboardName) else {
            return nil
        }
        return Self.resolveNaturalSize(proposal: proposal, natural: natural)
    }

    /// Proposal resolution for natural-size mode, `Image`-like: no axis → the
    /// authored size; one axis → the other derived from the aspect ratio;
    /// both → the proposal. Non-finite components count as unspecified.
    static func resolveNaturalSize(proposal: ProposedViewSize, natural: CGSize) -> CGSize? {
        guard natural.width > 0, natural.height > 0 else {
            return nil
        }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        switch (width, height) {
        case (nil, nil):
            return natural
        case (let width?, nil):
            return CGSize(width: width, height: width * natural.height / natural.width)
        case (nil, let height?):
            return CGSize(width: height * natural.width / natural.height, height: height)
        case (let width?, let height?):
            return CGSize(width: width, height: height)
        }
    }
}

#if canImport(UIKit)
extension RiveRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RiveUIView {
        makeView()
    }

    func updateUIView(_ uiView: RiveUIView, context: Context) {
        updateView(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RiveUIView, context: Context) -> CGSize? {
        naturalSize(for: proposal)
    }

    /// Teardown order matters: detach the view before releasing Rive
    /// (rive-ios #442/#418/#453).
    static func dismantleUIView(_ uiView: RiveUIView, coordinator: Coordinator) {
        coordinator.host.teardown()
        uiView.rive = nil
    }
}
#else
extension RiveRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> RiveUIView {
        makeView()
    }

    func updateNSView(_ nsView: RiveUIView, context: Context) {
        updateView(nsView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RiveUIView, context: Context) -> CGSize? {
        naturalSize(for: proposal)
    }

    /// Teardown order matters: detach the view before releasing Rive
    /// (rive-ios #442/#418/#453).
    static func dismantleNSView(_ nsView: RiveUIView, coordinator: Coordinator) {
        coordinator.host.teardown()
        nsView.rive = nil
    }
}
#endif
