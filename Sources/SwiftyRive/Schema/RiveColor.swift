import SwiftUI
internal import RiveRuntime

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// An sRGB color with components in the 0...1 range.
///
/// Rive's runtime stores colors as 8-bit ARGB. `RiveColor` keeps the public
/// API in familiar 0–1 `Double` space and performs the 0–255 conversion (and
/// the sRGB color-space resolution for platform colors) internally, so the
/// usual "wrong color space" footguns stay out of user code.
public nonisolated struct RiveColor: RivePropertyValue, Hashable, Sendable {
    /// Red component, 0...1.
    public var red: Double
    /// Green component, 0...1.
    public var green: Double
    /// Blue component, 0...1.
    public var blue: Double
    /// Alpha component, 0...1.
    public var alpha: Double

    /// Creates a color from 0...1 sRGB components. Values are clamped.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
        self.alpha = Self.clamped(alpha)
    }

    /// Creates a color from a SwiftUI `Color`, resolved in a default environment.
    ///
    /// Dynamic colors (light/dark variants, catalog colors) are resolved
    /// best-effort against a plain `EnvironmentValues()`; pass an explicit
    /// platform color when the exact variant matters.
    public init(_ color: SwiftUI.Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            alpha: Double(resolved.opacity)
        )
    }

    #if canImport(UIKit)
    /// Creates a color from a `UIColor`, converting to sRGB.
    public init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }
    #else
    /// Creates a color from an `NSColor`, converting to sRGB.
    ///
    /// Colors that cannot be represented in sRGB (e.g. pattern colors)
    /// fall back to opaque black.
    public init(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
            return
        }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent),
            alpha: Double(srgb.alphaComponent)
        )
    }
    #endif

    /// The color as a SwiftUI `Color` (sRGB).
    public var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func clamped(_ value: Double) -> Double {
        // `max(.nan, 0)` propagates NaN, and a non-finite component would trap
        // later in `UInt8((value * 255).rounded())`. Map NaN and -inf to 0 and
        // +inf to 1 so every component is a plain 0...1 value.
        guard value.isFinite else {
            return value == .infinity ? 1 : 0
        }
        return min(max(value, 0), 1)
    }
}

extension SwiftUI.Color {
    /// Creates a SwiftUI `Color` from a ``RiveColor`` (sRGB).
    ///
    /// The idiomatic conversion direction, mirroring `Color(uiColor:)`-style
    /// initializers: `Color(instance[\.tint])`.
    public init(_ riveColor: RiveColor) {
        self = riveColor.swiftUIColor
    }
}

// MARK: - Runtime conversion

extension RiveColor {
    /// Creates a color from the runtime's 8-bit ARGB representation.
    init(runtimeColor: RiveRuntime.Color) {
        self.init(
            red: Double(runtimeColor.red) / 255,
            green: Double(runtimeColor.green) / 255,
            blue: Double(runtimeColor.blue) / 255,
            alpha: Double(runtimeColor.alpha) / 255
        )
    }

    /// The runtime's 8-bit ARGB representation of this color.
    var runtimeColor: RiveRuntime.Color {
        RiveRuntime.Color(
            red: UInt8((red * 255).rounded()),
            green: UInt8((green * 255).rounded()),
            blue: UInt8((blue * 255).rounded()),
            alpha: UInt8((alpha * 255).rounded())
        )
    }
}
