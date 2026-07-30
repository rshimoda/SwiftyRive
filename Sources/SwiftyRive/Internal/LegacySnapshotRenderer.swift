import CoreGraphics
import Foundation
import Metal
import MetalKit
internal import RiveRuntime

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Renders a single frame through the legacy Objective-C `RiveRendererView`.
/// The Concurrency runtime keeps its render-to-texture machinery internal
/// (`RiveUIRenderer` needs artboard handles and the command queue, neither of
/// which is exposed), so this is the second and only other file that touches
/// legacy runtime types — same isolation discipline as
/// ``LegacyArtboardBounds``: legacy objects never escape, and callers get a
/// plain `CGImage`.
///
/// Delete when rive-ios ships a headless snapshot API (rive-ios #263 / #265).
@MainActor
enum LegacySnapshotRenderer {
    /// How long to wait for the GPU to finish the one frame before giving up.
    private static let gpuTimeout: Duration = .seconds(5)

    /// Parses `data` with the legacy runtime, advances the requested state
    /// machine, renders one frame offscreen, and returns the pixels.
    ///
    /// `loadCdn` is off, so CDN-hosted assets are not fetched; data binding is
    /// untouched, so the frame shows the file's default state.
    static func render(
        data: Data,
        artboardName: String?,
        stateMachineName: String?,
        pointSize: CGSize?,
        fit: RiveFit,
        scale: CGFloat,
        time: TimeInterval,
        availableArtboards: [String]
    ) async throws -> CGImage {
        guard scale > 0 else {
            throw RiveLoadError.snapshotUnavailable(reason: "scale must be positive, got \(scale)")
        }

        let file: RiveRuntime.RiveFile
        do {
            file = try RiveRuntime.RiveFile(data: data, loadCdn: false)
        } catch {
            throw RiveLoadError.parseFailed(description: error.localizedDescription)
        }

        let artboard: RiveRuntime.RiveArtboard
        do {
            artboard = try artboardName.map(file.artboard(fromName:)) ?? file.artboard()
        } catch {
            throw RiveLoadError.artboardNotFound(
                name: artboardName ?? "(default)",
                available: availableArtboards
            )
        }

        let size = pointSize ?? artboard.bounds().size
        guard size.width > 0, size.height > 0 else {
            throw RiveLoadError.snapshotUnavailable(reason: "render size must be positive, got \(size.width)x\(size.height)")
        }
        let pixelSize = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )

        // Layout fit sizes the artboard itself (mirrors the Concurrency
        // runtime's artboard.setSize(drawableSize, scale:)).
        let legacy = fit.legacySnapshotMapping
        if case .layout(let layoutScale) = fit.storage {
            let factor: CGFloat = switch layoutScale.storage {
            case .automatic: scale
            case .fixed(let value): CGFloat(value)
            }
            artboard.setWidth(Double(pixelSize.width / factor))
            artboard.setHeight(Double(pixelSize.height / factor))
        }

        // Pose: settle the initial state, then optionally move time forward.
        // The state machine advance also advances the artboard.
        if let stateMachineName {
            guard let machine = try? artboard.stateMachine(fromName: stateMachineName) else {
                throw RiveLoadError.stateMachineNotFound(name: stateMachineName, artboard: artboardName)
            }
            _ = machine.advance(by: 0)
            if time > 0 { _ = machine.advance(by: time) }
        } else if let machine = artboard.defaultStateMachine() {
            _ = machine.advance(by: 0)
            if time > 0 { _ = machine.advance(by: time) }
        } else {
            artboard.advance(by: 0)
            if time > 0 { artboard.advance(by: time) }
        }

        guard MTLCreateSystemDefaultDevice() != nil else {
            throw RiveLoadError.renderingUnavailable
        }

        // The legacy drawInRect: refuses to draw unless the view can resolve
        // a backing scale factor through its window, so the render view lives
        // in a window that is never shown. The view is sized in raw pixels
        // (its layer scale stays 1 offscreen) and fit/align maps content into
        // that rect; the artboard's device scale goes in via align's
        // scaleFactor, which only affects actualSize / scaleDown fits.
        let view = SnapshotRenderView(frame: CGRect(origin: .zero, size: pixelSize))
        view.artboardToDraw = artboard
        view.legacyFit = legacy.fit
        view.legacyAlignment = legacy.alignment
        view.deviceScale = scale
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false

        #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(origin: .zero, size: pixelSize))
        window.isHidden = true
        window.addSubview(view)
        view.contentScaleFactor = 1
        view.layer.contentsScale = 1
        #else
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: pixelSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layer?.contentsScale = 1
        #endif
        defer { view.removeFromSuperviewOrWindow() }

        // Pin the drawable size last: window insertion adopts the screen's
        // backing scale, which would silently multiply the drawable. The view
        // is already sized in pixels, so its layer is forced back to 1x above
        // — and no drawable may be acquired before this point.
        view.autoResizeDrawable = false
        view.drawableSize = pixelSize

        // drawInRect: runs synchronously through our drawRive override and
        // commits; the completion fires on a background thread when the GPU
        // finishes. A silent early return (no completion) is detected via the
        // override never running, so the timeout is a pure GPU safety net.
        let gate = SnapshotGate()
        drawFrame(in: view, signaling: gate)
        guard view.artboardWasDrawn, let texture = view.capturedTexture else {
            throw RiveLoadError.snapshotUnavailable(reason: "the renderer refused to draw (no drawable surface)")
        }
        guard await gate.wait(timeout: gpuTimeout) else {
            throw RiveLoadError.snapshotUnavailable(reason: "the GPU did not finish rendering in time")
        }

        guard let image = makeCGImage(from: texture) else {
            throw RiveLoadError.snapshotUnavailable(reason: "could not read the rendered pixels back from the GPU texture")
        }
        return image
    }

    /// Issues the one draw call. Deliberately synchronous (not the async
    /// import of `drawInRect:withCompletion:`): the legacy method returns
    /// without invoking its completion when it refuses to draw, which would
    /// suspend the async form forever. The caller instead checks
    /// ``SnapshotRenderView/artboardWasDrawn`` and waits on the gate.
    private static func drawFrame(in view: SnapshotRenderView, signaling gate: SnapshotGate) {
        view.draw(in: view.bounds) { _ in
            gate.signal()
        }
    }

    // MARK: - Texture readback

    /// Copies a BGRA texture into a `CGImage`.
    private static func makeCGImage(from texture: any MTLTexture) -> CGImage? {
        guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb else {
            Log.engine.error("Snapshot texture has unsupported pixel format \(texture.pixelFormat.rawValue)")
            return nil
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// MARK: - Render view

/// Offscreen `RiveRendererView` that draws exactly one artboard frame and
/// captures the drawable's texture for readback.
@MainActor
private final class SnapshotRenderView: RiveRuntime.RiveRendererView {
    var artboardToDraw: RiveRuntime.RiveArtboard?
    var legacyFit: RiveRuntime.RiveFit = .contain
    var legacyAlignment: RiveRuntime.RiveAlignment = .center
    var deviceScale: CGFloat = 1
    private(set) var artboardWasDrawn = false
    private(set) var capturedTexture: (any MTLTexture)?

    override func drawRive(_ rect: CGRect, size: CGSize) {
        guard let artboardToDraw else { return }
        artboardWasDrawn = true
        capturedTexture = currentDrawable?.texture
        align(
            with: rect,
            contentRect: artboardToDraw.bounds(),
            alignment: legacyAlignment,
            fit: legacyFit,
            scaleFactor: deviceScale
        )
        draw(with: artboardToDraw)
    }

    func removeFromSuperviewOrWindow() {
        #if canImport(UIKit)
        removeFromSuperview()
        #else
        window?.contentView = nil
        #endif
    }
}

// MARK: - GPU completion gate

/// Bridges the legacy completion callback (background thread) to async code,
/// resolving exactly once: GPU completion and the timeout race, first one wins.
private nonisolated final class SnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Called from the legacy completion handler when the GPU frame is done.
    func signal() {
        resolve(with: true)
    }

    /// Suspends until ``signal()`` or the timeout, whichever comes first.
    func wait(timeout: Duration) async -> Bool {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resolve(with: false)
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func resolve(with value: Bool) {
        lock.lock()
        signaled = signaled || value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

// MARK: - Fit mapping

extension RiveFit {
    /// Maps the package fit (and its embedded alignment) onto the legacy
    /// runtime's enums for the snapshot renderer.
    fileprivate nonisolated var legacySnapshotMapping: (fit: RiveRuntime.RiveFit, alignment: RiveRuntime.RiveAlignment) {
        switch storage {
        case .fill(let alignment): (.fill, alignment.legacyAlignment)
        case .contain(let alignment): (.contain, alignment.legacyAlignment)
        case .cover(let alignment): (.cover, alignment.legacyAlignment)
        case .fitWidth(let alignment): (.fitWidth, alignment.legacyAlignment)
        case .fitHeight(let alignment): (.fitHeight, alignment.legacyAlignment)
        case .scaleDown(let alignment): (.scaleDown, alignment.legacyAlignment)
        case .actualSize(let alignment): (.noFit, alignment.legacyAlignment)
        case .layout: (.layout, .center)
        }
    }
}

extension RiveAlignment {
    fileprivate nonisolated var legacyAlignment: RiveRuntime.RiveAlignment {
        switch storage {
        case .topLeading: .topLeft
        case .top: .topCenter
        case .topTrailing: .topRight
        case .leading: .centerLeft
        case .center: .center
        case .trailing: .centerRight
        case .bottomLeading: .bottomLeft
        case .bottom: .bottomCenter
        case .bottomTrailing: .bottomRight
        }
    }
}
