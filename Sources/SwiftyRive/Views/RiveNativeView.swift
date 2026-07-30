import Foundation
internal import RiveRuntime

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Shared implementation behind the platform-specific ``RiveNativeView``
/// classes: owns the render host and the hosted runtime view, and applies
/// configuration changes.
@MainActor
private final class RiveNativeCore {
    let document: RiveDocument
    let artboardName: String?

    private let stateMachineName: String?
    private let boundViewModelInstance: RiveRuntime.ViewModelInstance?
    private let attachRenderHost: ((RiveRenderHost) -> Void)?

    /// Internal (not `private`) so ``RiveNativeView`` can expose it to tests;
    /// the class itself is file-private, so nothing leaks.
    let host = RiveRenderHost()
    private let hostedView: RiveUIView
    private var applyTask: Task<Void, Never>?

    var fit: RiveFit = .contain {
        didSet {
            guard fit != oldValue else { return }
            applyConfiguration()
        }
    }

    var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            hostedView.isPaused = isPaused
            host.adoptHostedView(hostedView, desiredIsPaused: isPaused)
        }
    }

    init(
        document: RiveDocument,
        artboardName: String?,
        stateMachineName: String?,
        boundViewModelInstance: RiveRuntime.ViewModelInstance?,
        attachRenderHost: ((RiveRenderHost) -> Void)?
    ) {
        self.document = document
        self.artboardName = artboardName
        self.stateMachineName = stateMachineName
        self.boundViewModelInstance = boundViewModelInstance
        self.attachRenderHost = attachRenderHost
        hostedView = RiveUIView(rive: nil, isPaused: false)
        host.adoptHostedView(hostedView, desiredIsPaused: false)
        applyConfiguration()
    }

    /// `isolated deinit` runs teardown on the main actor before stored
    /// properties are released (rive-ios #442/#418/#453).
    isolated deinit {
        applyTask?.cancel()
        host.teardown()
    }

    /// Pins the hosted runtime view to the container's edges.
    func embedHostedView(in container: RiveRuntime.NativeView) {
        container.addSubview(hostedView)
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// The artboard's authored size, or a square of `fallbackMetric`
    /// (the platform's `noIntrinsicMetric`) when the size cannot be read.
    func intrinsicContentSize(fallbackMetric: CGFloat) -> CGSize {
        guard let size = try? document.artboardSize(named: artboardName),
              size.width > 0, size.height > 0 else {
            return CGSize(width: fallbackMetric, height: fallbackMetric)
        }
        return size
    }

    private func applyConfiguration() {
        let configuration = RiveRenderHost.Configuration(
            document: document,
            artboardName: artboardName,
            stateMachineName: stateMachineName,
            fit: fit,
            boundViewModelInstance: boundViewModelInstance
        )
        applyTask?.cancel()
        applyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await host.apply(configuration)
            guard !Task.isCancelled else { return }
            if hostedView.rive !== host.rive {
                hostedView.rive = host.rive
            }
            attachRenderHost?(host)
        }
    }
}

#if canImport(UIKit)
/// A `UIView` escape hatch for hosting Rive content outside SwiftUI.
///
/// Prefer ``RiveView`` in SwiftUI. This class exists for UIKit view
/// hierarchies and reports the artboard's authored size as its
/// `intrinsicContentSize` — a local fix for the missing size API in the
/// runtime (rive-ios issue #323). When the size cannot be read, it falls
/// back to `noIntrinsicMetric` on both axes.
@MainActor
public final class RiveNativeView: UIView {
    private let core: RiveNativeCore

    /// The render host backing this view. Test/introspection hook.
    var renderHostForTesting: RiveRenderHost { core.host }

    /// How the artboard is scaled and positioned within the view's bounds.
    /// Defaults to ``RiveFit/contain``.
    public var fit: RiveFit {
        get { core.fit }
        set { core.fit = newValue }
    }

    /// Whether playback is paused. Defaults to `false`.
    public var isPaused: Bool {
        get { core.isPaused }
        set { core.isPaused = newValue }
    }

    /// Creates a view rendering an artboard from `document`.
    ///
    /// - Parameters:
    ///   - document: The loaded document to render from.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(document: RiveDocument, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: nil,
            attachRenderHost: nil
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Creates a view rendering an artboard bound to a typed ``RiveInstance``.
    ///
    /// - Parameters:
    ///   - instance: The bound instance created via ``RiveDocument/makeInstance(of:artboard:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init<S: RiveSchema>(instance: RiveInstance<S>, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: instance.document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: instance.viewModelInstance,
            attachRenderHost: { [weak instance] host in
                instance?.renderHost = host
            }
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Creates a view rendering an artboard bound to a ``RiveDynamicInstance``.
    ///
    /// - Parameters:
    ///   - instance: The dynamic instance created via ``RiveDocument/makeDynamicInstance(artboard:viewModel:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(instance: RiveDynamicInstance, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: instance.document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: instance.viewModelInstance,
            attachRenderHost: { [weak instance] host in
                instance?.renderHost = host
            }
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Not supported — create ``RiveNativeView`` in code.
    public required init?(coder: NSCoder) {
        return nil
    }

    /// The artboard's authored size (see ``RiveDocument/artboardSize(named:)``),
    /// or `noIntrinsicMetric` on both axes when the size cannot be read.
    public override var intrinsicContentSize: CGSize {
        core.intrinsicContentSize(fallbackMetric: Self.noIntrinsicMetric)
    }
}
#else
/// An `NSView` escape hatch for hosting Rive content outside SwiftUI.
///
/// Prefer ``RiveView`` in SwiftUI. This class exists for AppKit view
/// hierarchies and reports the artboard's authored size as its
/// `intrinsicContentSize` — a local fix for the missing size API in the
/// runtime (rive-ios issue #323). When the size cannot be read, it falls
/// back to `noIntrinsicMetric` on both axes.
@MainActor
public final class RiveNativeView: NSView {
    private let core: RiveNativeCore

    /// The render host backing this view. Test/introspection hook.
    var renderHostForTesting: RiveRenderHost { core.host }

    /// How the artboard is scaled and positioned within the view's bounds.
    /// Defaults to ``RiveFit/contain``.
    public var fit: RiveFit {
        get { core.fit }
        set { core.fit = newValue }
    }

    /// Whether playback is paused. Defaults to `false`.
    public var isPaused: Bool {
        get { core.isPaused }
        set { core.isPaused = newValue }
    }

    /// Creates a view rendering an artboard from `document`.
    ///
    /// - Parameters:
    ///   - document: The loaded document to render from.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(document: RiveDocument, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: nil,
            attachRenderHost: nil
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Creates a view rendering an artboard bound to a typed ``RiveInstance``.
    ///
    /// - Parameters:
    ///   - instance: The bound instance created via ``RiveDocument/makeInstance(of:artboard:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init<S: RiveSchema>(instance: RiveInstance<S>, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: instance.document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: instance.viewModelInstance,
            attachRenderHost: { [weak instance] host in
                instance?.renderHost = host
            }
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Creates a view rendering an artboard bound to a ``RiveDynamicInstance``.
    ///
    /// - Parameters:
    ///   - instance: The dynamic instance created via ``RiveDocument/makeDynamicInstance(artboard:viewModel:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(instance: RiveDynamicInstance, artboard: String? = nil, stateMachine: String? = nil) {
        core = RiveNativeCore(
            document: instance.document,
            artboardName: artboard,
            stateMachineName: stateMachine,
            boundViewModelInstance: instance.viewModelInstance,
            attachRenderHost: { [weak instance] host in
                instance?.renderHost = host
            }
        )
        super.init(frame: .zero)
        core.embedHostedView(in: self)
    }

    /// Not supported — create ``RiveNativeView`` in code.
    public required init?(coder: NSCoder) {
        return nil
    }

    /// The artboard's authored size (see ``RiveDocument/artboardSize(named:)``),
    /// or `noIntrinsicMetric` on both axes when the size cannot be read.
    public override var intrinsicContentSize: CGSize {
        core.intrinsicContentSize(fallbackMetric: Self.noIntrinsicMetric)
    }
}
#endif
