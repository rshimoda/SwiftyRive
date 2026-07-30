import SwiftUI

nonisolated extension EnvironmentValues {
    /// How Rive artboards in this environment are scaled and positioned. Defaults to ``RiveFit/contain``.
    @Entry var riveFit: RiveFit = .contain
    /// Whether Rive animations in this environment are paused. Defaults to `false`.
    @Entry var rivePaused: Bool = false
    /// The preferred frame rate for Rive rendering, or `nil` for the display default.
    @Entry var riveFrameRate: Int? = nil
    /// Whether Rive views size themselves to their artboard's authored size. Defaults to `false` (greedy).
    @Entry var riveNaturalSize: Bool = false
}

extension View {
    /// Sets how Rive artboards are scaled and positioned within their bounds.
    ///
    /// Fit affects rendering only; it never changes the view's layout size.
    public func riveFit(_ fit: RiveFit) -> some View {
        environment(\.riveFit, fit)
    }

    /// Pauses or resumes Rive animations.
    public func rivePaused(_ isPaused: Bool) -> some View {
        environment(\.rivePaused, isPaused)
    }

    /// Sets the preferred frame rate (frames per second) for Rive rendering.
    ///
    /// Pass `nil` to restore the display's default frame rate — useful for
    /// undoing a cap set higher in the view hierarchy.
    public func riveFrameRate(_ framesPerSecond: Int?) -> some View {
        environment(\.riveFrameRate, framesPerSecond)
    }

    /// Sizes Rive views to their artboard's authored size instead of greedily
    /// filling the proposed space.
    ///
    /// With this modifier applied, a ``RiveView`` participates in layout like
    /// `Image` does: when neither axis is proposed it reports the artboard's
    /// authored size, when one axis is proposed the other is derived from the
    /// artboard's aspect ratio, and when both axes are proposed the proposal wins.
    ///
    /// The natural size is always the size the artboard was **authored** at in
    /// the Rive editor — including with ``RiveFit/layout(scale:)``, whose
    /// responsive layout engine reflows content *inside* the rect that layout
    /// provides but never changes the authored size this modifier reports.
    ///
    /// If the artboard's size cannot be determined (for example the bytes can
    /// no longer be read), the view falls back to the default greedy behavior.
    public func riveNaturalSize() -> some View {
        environment(\.riveNaturalSize, true)
    }
}
