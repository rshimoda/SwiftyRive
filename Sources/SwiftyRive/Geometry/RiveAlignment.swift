import SwiftUI
internal import RiveRuntime

/// The alignment of an artboard within its rendering bounds.
///
/// Uses SwiftUI-style naming (`leading`/`trailing`). The Rive runtime has no
/// right-to-left awareness, so `leading` always maps to left and `trailing` to right.
public nonisolated struct RiveAlignment: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case topLeading, top, topTrailing
        case leading, center, trailing
        case bottomLeading, bottom, bottomTrailing
    }

    let storage: Storage

    /// Aligns to the top-leading corner.
    public static let topLeading = RiveAlignment(storage: .topLeading)
    /// Aligns to the top edge, centered horizontally.
    public static let top = RiveAlignment(storage: .top)
    /// Aligns to the top-trailing corner.
    public static let topTrailing = RiveAlignment(storage: .topTrailing)
    /// Aligns to the leading edge, centered vertically.
    public static let leading = RiveAlignment(storage: .leading)
    /// Centers on both axes.
    public static let center = RiveAlignment(storage: .center)
    /// Aligns to the trailing edge, centered vertically.
    public static let trailing = RiveAlignment(storage: .trailing)
    /// Aligns to the bottom-leading corner.
    public static let bottomLeading = RiveAlignment(storage: .bottomLeading)
    /// Aligns to the bottom edge, centered horizontally.
    public static let bottom = RiveAlignment(storage: .bottom)
    /// Aligns to the bottom-trailing corner.
    public static let bottomTrailing = RiveAlignment(storage: .bottomTrailing)

    private init(storage: Storage) {
        self.storage = storage
    }

    /// Creates an alignment from a SwiftUI alignment.
    ///
    /// Alignments without a Rive counterpart (e.g. text-baseline alignments) fall back to `.center`.
    public init(_ alignment: SwiftUI.Alignment) {
        switch alignment {
        case .topLeading: storage = .topLeading
        case .top: storage = .top
        case .topTrailing: storage = .topTrailing
        case .leading: storage = .leading
        case .trailing: storage = .trailing
        case .bottomLeading: storage = .bottomLeading
        case .bottom: storage = .bottom
        case .bottomTrailing: storage = .bottomTrailing
        default: storage = .center
        }
    }

    /// The single mapping point onto the runtime alignment type.
    var runtimeAlignment: RiveRuntime.Alignment {
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
