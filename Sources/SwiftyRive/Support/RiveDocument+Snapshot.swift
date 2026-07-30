import CoreGraphics
import Foundation

extension RiveDocument {
    /// Renders a single frame headlessly and returns it as a `CGImage`.
    ///
    /// No view, window, or running animation is involved — the frame is drawn
    /// offscreen, which makes this suitable for snapshot tests, previews,
    /// posters, and thumbnails (rive-ios #263 / #265).
    ///
    /// The rendered pose is the state machine's state after its initial
    /// advance, optionally moved forward by `time` seconds. Data binding is
    /// not applied: the frame shows the file's default values.
    ///
    /// ```swift
    /// let document = try await RiveDocument.load(.bundle("badge"))
    /// let poster = try await document.snapshot()
    /// Image(decorative: poster, scale: 2)
    /// ```
    ///
    /// - Parameters:
    ///   - artboard: The artboard to render, or `nil` for the file's default.
    ///   - stateMachine: The state machine to pose, or `nil` for the
    ///     artboard's default (falling back to a static frame when the
    ///     artboard has none).
    ///   - size: The frame's size in points, or `nil` for the artboard's
    ///     authored size. Rendering honors `fit` inside this rect.
    ///   - fit: How the artboard maps into `size`. Defaults to ``RiveFit/contain``.
    ///   - scale: Pixels per point. The default of 2 matches Retina displays,
    ///     so the returned image is `size` × 2 pixels; wrap it with
    ///     `Image(decorative:scale:)` using the same value.
    ///   - time: Seconds to advance the state machine past its initial state
    ///     before rendering.
    /// - Returns: The rendered frame, `size` × `scale` pixels.
    /// - Throws: ``RiveLoadError/artboardNotFound(name:available:)``,
    ///   ``RiveLoadError/stateMachineNotFound(name:artboard:)``,
    ///   ``RiveLoadError/renderingUnavailable`` when no Metal device exists,
    ///   or ``RiveLoadError/snapshotUnavailable(reason:)`` when the offscreen
    ///   renderer cannot produce a frame.
    public func snapshot(
        artboard: String? = nil,
        stateMachine: String? = nil,
        size: CGSize? = nil,
        fit: RiveFit = .contain,
        scale: CGFloat = 2,
        at time: TimeInterval = 0
    ) async throws -> CGImage {
        if let artboard, !artboardNames.isEmpty, !artboardNames.contains(artboard) {
            throw RiveLoadError.artboardNotFound(name: artboard, available: artboardNames)
        }
        return try await LegacySnapshotRenderer.render(
            data: bytesRedownloadingIfNeeded(),
            artboardName: artboard,
            stateMachineName: stateMachine,
            pointSize: size,
            fit: fit,
            scale: scale,
            time: time,
            availableArtboards: artboardNames
        )
    }
}
