import SwiftUI
internal import RiveRuntime

/// A SwiftUI view that renders an artboard from a loaded ``RiveDocument``.
///
/// ```swift
/// RiveView(document, artboard: "Hero", stateMachine: "Idle")
///     .riveFit(.cover)
/// ```
///
/// Fit, pause state, and frame rate are read from the environment — see
/// ``SwiftUICore/View/riveFit(_:)``, ``SwiftUICore/View/rivePaused(_:)``, and
/// ``SwiftUICore/View/riveFrameRate(_:)``. Changing `artboard` or `stateMachine`
/// rebuilds the render configuration; the parsed document stays cached.
public struct RiveView: View {
    private let document: RiveDocument
    private let artboardName: String?
    private let stateMachineName: String?
    private let boundViewModelInstance: RiveRuntime.ViewModelInstance?
    private let instanceIdentity: ObjectIdentifier?
    private let attachRenderHost: (@MainActor (RiveRenderHost) -> Void)?

    @Environment(\.riveFit) private var fit
    @Environment(\.rivePaused) private var isPaused
    @Environment(\.riveFrameRate) private var frameRate
    @Environment(\.riveNaturalSize) private var usesNaturalSize

    @State private var host = RiveRenderHost()

    /// Creates a view rendering an artboard from `document`.
    ///
    /// Data binding uses the runtime's automatic mode (the artboard's default
    /// view model instance, when it has one).
    ///
    /// - Parameters:
    ///   - document: The loaded document to render from.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(_ document: RiveDocument, artboard: String? = nil, stateMachine: String? = nil) {
        self.document = document
        self.artboardName = artboard
        self.stateMachineName = stateMachine
        self.boundViewModelInstance = nil
        self.instanceIdentity = nil
        self.attachRenderHost = nil
    }

    /// Creates a view rendering an artboard bound to a typed ``RiveInstance``.
    ///
    /// The instance's view model instance is bound to the state machine
    /// (`dataBind: .instance`), and the view registers itself with the
    /// instance so writes made while playback is paused still render
    /// (advance-nudge, workaround for rive-ios #383).
    ///
    /// - Parameters:
    ///   - instance: The bound instance created via ``RiveDocument/makeInstance(of:artboard:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init<S: RiveSchema>(
        _ instance: RiveInstance<S>,
        artboard: String? = nil,
        stateMachine: String? = nil
    ) {
        self.init(bindable: instance, artboard: artboard, stateMachine: stateMachine)
    }

    /// Creates a view rendering an artboard bound to a ``RiveDynamicInstance``.
    ///
    /// Same binding behavior as the typed variant: `dataBind: .instance` plus
    /// render-host registration for paused-write nudging.
    ///
    /// - Parameters:
    ///   - instance: The bound instance created via
    ///     ``RiveDocument/makeDynamicInstance(artboard:viewModel:)``.
    ///   - artboard: The artboard name, or `nil` for the file's default artboard.
    ///   - stateMachine: The state machine name, or `nil` for the artboard's default.
    public init(
        _ instance: RiveDynamicInstance,
        artboard: String? = nil,
        stateMachine: String? = nil
    ) {
        self.init(bindable: instance, artboard: artboard, stateMachine: stateMachine)
    }

    /// Shared setup for both bound-instance variants.
    private init(
        bindable instance: any RiveBindableInstance,
        artboard: String?,
        stateMachine: String?
    ) {
        self.document = instance.document
        self.artboardName = artboard
        self.stateMachineName = stateMachine
        self.boundViewModelInstance = instance.viewModelInstance
        self.instanceIdentity = ObjectIdentifier(instance)
        self.attachRenderHost = { [weak instance] host in
            instance?.renderHost = host
        }
    }

    public var body: some View {
        RiveRepresentable(
            rive: host.rive,
            isPaused: isPaused,
            framesPerSecond: frameRate,
            host: host,
            document: document,
            artboardName: artboardName,
            usesNaturalSize: usesNaturalSize
        )
            .task(id: renderID) {
                await host.apply(
                    RiveRenderHost.Configuration(
                        document: document,
                        artboardName: artboardName,
                        stateMachineName: stateMachineName,
                        fit: fit,
                        boundViewModelInstance: boundViewModelInstance
                    )
                )
                attachRenderHost?(host)
            }
            .onDisappear {
                host.teardown()
            }
    }

    private var renderID: RenderID {
        RenderID(
            document: ObjectIdentifier(document),
            artboard: artboardName,
            stateMachine: stateMachineName,
            fit: fit,
            instance: instanceIdentity
        )
    }
}

/// The common surface of typed and dynamic bound instances that ``RiveView``
/// needs: the owning document, the runtime instance to bind, and the render
/// host hookup for paused-write nudging.
@MainActor
protocol RiveBindableInstance: AnyObject {
    var document: RiveDocument { get }
    var viewModelInstance: RiveRuntime.ViewModelInstance { get }
    var renderHost: RiveRenderHost? { get set }
}

extension RiveInstance: RiveBindableInstance {}
extension RiveDynamicInstance: RiveBindableInstance {}

/// Identity of the current render configuration, used as the `.task(id:)` trigger.
private nonisolated struct RenderID: Hashable {
    let document: ObjectIdentifier
    let artboard: String?
    let stateMachine: String?
    let fit: RiveFit
    let instance: ObjectIdentifier?
}

// MARK: - Preview

#if DEBUG
/// Reads the local, git-ignored preview asset if present on this machine.
///
/// The asset is proprietary and lives only in `LocalAssets/` (never committed);
/// the preview degrades gracefully when the file is absent.
private func previewAssetData() -> Data? {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Views
        .deletingLastPathComponent() // SwiftyRive
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // package root
    let assetURL = packageRoot.appendingPathComponent("LocalAssets/main.riv")
    guard FileManager.default.fileExists(atPath: assetURL.path) else {
        return nil
    }
    return try? Data(contentsOf: assetURL)
}

#Preview("BG_Rainbow") {
    Group {
        if let data = previewAssetData() {
            AsyncRiveView(source: .data(data, identifier: "preview.main.riv"), artboard: "BG_Rainbow") { phase in
                switch phase {
                case .loading:
                    ProgressView()
                case .success(let view):
                    view
                case .failure(let error):
                    Text(error.localizedDescription)
                        .padding()
                }
            }
        } else {
            Text("Add main.riv to LocalAssets/ to see this preview.")
                .padding()
        }
    }
    .frame(width: 480, height: 360)
}

/// Schema for the local `main.riv` preview asset. Its view models are
/// per-artboard; "Animated_Text" carries `text`.
private nonisolated struct MainAssetSchema: RiveSchema {
    static var viewModelName: String? { "Animated_Text" }

    let text = RiveKey<String>("text")
}

/// Loads the local asset, binds `MainAssetSchema`, and drives it two ways.
private struct BoundSchemaPreview: View {
    let data: Data

    @State private var instance: RiveInstance<MainAssetSchema>?
    @State private var loadError: (any Error)?

    var body: some View {
        Group {
            if let instance {
                VStack(spacing: 12) {
                    RiveView(instance, artboard: "Animated_Text")
                        .frame(height: 240)

                    TextField("text", text: instance.binding(for: \.text))
                        .textFieldStyle(.roundedBorder)
                }
                .padding()
            } else if let loadError {
                Text(loadError.localizedDescription)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let document = try await RiveDocument.load(.data(data, identifier: "preview.main.riv"))
                instance = try await document.makeInstance(of: MainAssetSchema.self)
            } catch {
                loadError = error
            }
        }
    }
}

#Preview("Bound schema") {
    Group {
        if let data = previewAssetData() {
            BoundSchemaPreview(data: data)
        } else {
            Text("Add main.riv to LocalAssets/ to see this preview.")
                .padding()
        }
    }
    .frame(width: 480, height: 420)
}

/// Switches artboards on a single bound ``RiveInstance``: the instance must
/// survive every switch, switching must be hitch-free, and paused writes
/// must still render.
private struct ArtboardSwitcherPreview: View {
    let data: Data

    @State private var instance: RiveInstance<MainAssetSchema>?
    @State private var loadError: (any Error)?
    @State private var artboard = "BG_Color"
    @State private var isPaused = false

    private static let artboards = ["BG_Color", "BG_Rainbow", "Animated_Text"]

    var body: some View {
        Group {
            if let instance {
                VStack(spacing: 12) {
                    RiveView(instance, artboard: artboard)
                        .rivePaused(isPaused)
                        .frame(height: 240)

                    Picker("Artboard", selection: $artboard) {
                        ForEach(Self.artboards, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Paused (writes below must still render)", isOn: $isPaused)

                    TextField("text", text: instance.binding(for: \.text))
                        .textFieldStyle(.roundedBorder)
                }
                .padding()
            } else if let loadError {
                Text(loadError.localizedDescription)
                    .padding()
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let document = try await RiveDocument.load(.data(data, identifier: "preview.main.riv"))
                instance = try await document.makeInstance(of: MainAssetSchema.self)
            } catch {
                loadError = error
            }
        }
    }
}

#Preview("Artboard switcher") {
    Group {
        if let data = previewAssetData() {
            ArtboardSwitcherPreview(data: data)
        } else {
            Text("Add main.riv to LocalAssets/ to see this preview.")
                .padding()
        }
    }
    .frame(width: 480, height: 480)
}

/// Demonstrates `.riveNaturalSize()`: the view takes its artboard's authored
/// size inside a `VStack` with no explicit frames anywhere.
private struct NaturalSizePreview: View {
    let data: Data

    @State private var document: RiveDocument?
    @State private var loadError: (any Error)?

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 12) {
                    Text("Content above")
                    RiveView(document, artboard: "Animated_Text")
                        .riveNaturalSize()
                        .border(.quaternary)
                    Text("Content below")
                }
            } else if let loadError {
                Text(loadError.localizedDescription)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                document = try await RiveDocument.load(.data(data, identifier: "preview.main.riv"))
            } catch {
                loadError = error
            }
        }
    }
}

#Preview("Natural size") {
    Group {
        if let data = previewAssetData() {
            NaturalSizePreview(data: data)
        } else {
            Text("Add main.riv to LocalAssets/ to see this preview.")
        }
    }
    .padding()
}
#endif
