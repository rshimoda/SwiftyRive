#if DEBUG
import SwiftUI

/// Scratch pad for tuning the recents tile's glass. Open this file's canvas and
/// edit the numbers: `band` is how far the material reaches in from the edge
/// (`nil` covers the whole tile), `radius` matches the tile's corner, and the
/// artwork below stands in for a rendered `.riv` frame — fine text and hard
/// edges make refraction easy to judge.
private struct GlassSample: View {
    var band: CGFloat?
    var isClear = true
    var radius: CGFloat = 10

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        SampleArtwork()
            .frame(width: 240, height: 180)
            .clipShape(shape)
            .overlay { rim }
    }

    @ViewBuilder
    private var rim: some View {
        let hairline = shape.strokeBorder(.quaternary, lineWidth: 1)
        if #available(iOS 26.0, macOS 26.0, *) {
            let glass = hairline.glassEffect(isClear ? .clear : .regular, in: shape)
            if let band {
                glass.mask { shape.strokeBorder(lineWidth: band) }
            } else {
                glass
            }
        } else {
            hairline
        }
    }
}

/// Stands in for a rendered Rive frame: a gradient with small text rows, so
/// both smooth areas and sharp glyphs are available to judge distortion on.
private struct SampleArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.24, green: 0.19, blue: 0.31), Color(red: 0.42, green: 0.3, blue: 0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["String", "Number", "Boolean", "Color", "Enum", "Trigger"], id: \.self) { label in
                    HStack {
                        Text(label)
                        Spacer()
                        Text(label)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .padding(12)
        }
    }
}

/// Drag the band width to find the point where the rim reads as glass and the
/// middle still reads as a plain picture.
private struct GlassTuner: View {
    @State private var band: CGFloat = 14
    @State private var isClear = true
    @State private var radius: CGFloat = 10

    var body: some View {
        VStack(spacing: 20) {
            GlassSample(band: band, isClear: isClear, radius: radius)
            VStack(alignment: .leading) {
                LabeledContent("Band") {
                    Slider(value: $band, in: 0...60) { Text("Band") }
                }
                LabeledContent("Corner") {
                    Slider(value: $radius, in: 0...40) { Text("Corner") }
                }
                Toggle("Clear glass", isOn: $isClear)
                Text("band \(Int(band))pt · corner \(Int(radius))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320)
        }
        .padding(24)
    }
}

#Preview("Tuner") {
    GlassTuner()
}

#Preview("Side by side") {
    VStack(spacing: 24) {
        LabeledContent("No glass") { GlassSample(band: 0) }
        LabeledContent("Rim 14pt") { GlassSample(band: 5) }
        LabeledContent("Rim 28pt") { GlassSample(band: 6) }
        LabeledContent("Whole tile") { GlassSample(band: nil, isClear: true, radius: 4) }
        LabeledContent("Whole tile, regular") { GlassSample(band: nil, isClear: false) }
    }
    .padding(24)
}
#endif
