import Foundation
internal import RiveRuntime

/// How an artboard is scaled and positioned within the view's bounds.
///
/// Fit affects rendering only — it never changes the view's layout size.
/// The default used by ``RiveView`` is ``contain``.
public nonisolated struct RiveFit: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case fill(RiveAlignment)
        case contain(RiveAlignment)
        case cover(RiveAlignment)
        case fitWidth(RiveAlignment)
        case fitHeight(RiveAlignment)
        case scaleDown(RiveAlignment)
        case actualSize(RiveAlignment)
        case layout(RiveLayoutScale)
    }

    let storage: Storage

    /// Scales to fit entirely within the bounds, preserving aspect ratio (centered).
    public static let contain = RiveFit(storage: .contain(.center))
    /// Scales to cover the entire bounds, preserving aspect ratio (centered); may crop.
    public static let cover = RiveFit(storage: .cover(.center))
    /// Stretches to fill the bounds exactly, ignoring aspect ratio.
    public static let fill = RiveFit(storage: .fill(.center))
    /// Scales to match the bounds width, preserving aspect ratio (centered).
    public static let fitWidth = RiveFit(storage: .fitWidth(.center))
    /// Scales to match the bounds height, preserving aspect ratio (centered).
    public static let fitHeight = RiveFit(storage: .fitHeight(.center))
    /// Scales down only when larger than the bounds; never scales up (centered).
    public static let scaleDown = RiveFit(storage: .scaleDown(.center))
    /// Renders at the artboard's original size without any scaling (centered).
    public static let actualSize = RiveFit(storage: .actualSize(.center))

    /// Scales to fit entirely within the bounds, preserving aspect ratio.
    public static func contain(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .contain(alignment))
    }

    /// Scales to cover the entire bounds, preserving aspect ratio; may crop.
    public static func cover(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .cover(alignment))
    }

    /// Stretches to fill the bounds exactly, ignoring aspect ratio.
    public static func fill(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .fill(alignment))
    }

    /// Scales to match the bounds width, preserving aspect ratio.
    public static func fitWidth(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .fitWidth(alignment))
    }

    /// Scales to match the bounds height, preserving aspect ratio.
    public static func fitHeight(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .fitHeight(alignment))
    }

    /// Scales down only when larger than the bounds; never scales up.
    public static func scaleDown(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .scaleDown(alignment))
    }

    /// Renders at the artboard's original size without any scaling.
    public static func actualSize(alignment: RiveAlignment = .center) -> RiveFit {
        RiveFit(storage: .actualSize(alignment))
    }

    /// Uses Rive's responsive layout engine with the given scale.
    ///
    /// Alignment has no effect in layout mode — the layout engine positions content itself.
    public static func layout(scale: RiveLayoutScale = .automatic) -> RiveFit {
        RiveFit(storage: .layout(scale))
    }

    /// The single mapping point onto the runtime fit type.
    var runtimeFit: RiveRuntime.Fit {
        switch storage {
        case .fill(let alignment): .fill(alignment: alignment.runtimeAlignment)
        case .contain(let alignment): .contain(alignment: alignment.runtimeAlignment)
        case .cover(let alignment): .cover(alignment: alignment.runtimeAlignment)
        case .fitWidth(let alignment): .fitWidth(alignment: alignment.runtimeAlignment)
        case .fitHeight(let alignment): .fitHeight(alignment: alignment.runtimeAlignment)
        case .scaleDown(let alignment): .scaleDown(alignment: alignment.runtimeAlignment)
        case .actualSize(let alignment): .none(alignment: alignment.runtimeAlignment)
        case .layout(let scale):
            switch scale.storage {
            case .automatic: .layout(scaleFactor: .automatic)
            case .fixed(let value): .layout(scaleFactor: .explicit(Float(value)))
            }
        }
    }
}

/// The scale used by ``RiveFit/layout(scale:)``.
public nonisolated struct RiveLayoutScale: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case automatic
        case fixed(Double)
    }

    let storage: Storage

    /// Derives the scale from the display's native scale factor.
    public static let automatic = RiveLayoutScale(storage: .automatic)

    /// Uses a fixed, explicit scale factor.
    public static func fixed(_ scale: Double) -> RiveLayoutScale {
        RiveLayoutScale(storage: .fixed(scale))
    }
}
