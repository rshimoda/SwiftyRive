import Foundation
import SwiftUI
import Testing
@testable import SwiftyRive

/// The ``RiveSource`` cache-key contract: two sources are equal exactly when
/// they would resolve to the same bytes, so the engine cache can key on them.
struct RiveSourceTests {
    private nonisolated static let bytes = Data([0x52, 0x49, 0x56, 0x45])

    @Test func identicalBundleSourcesAreEqual() {
        #expect(RiveSource.bundle("robot") == RiveSource.bundle("robot"))
        #expect(RiveSource.bundle("robot") != RiveSource.bundle("hero"))
    }

    @Test func dataSourcesAreKeyedByIdentifierAndBytes() {
        let data = Self.bytes
        #expect(RiveSource.data(data, identifier: "a") == RiveSource.data(data, identifier: "a"))
        #expect(RiveSource.data(data, identifier: "a") != RiveSource.data(data, identifier: "b"))
    }

    @Test func urlSourcesAreKeyedByURL() {
        let url = URL(string: "https://example.com/robot.riv")!
        #expect(RiveSource.url(url) == RiveSource.url(url))
    }

    /// Pairs that must never collide in the cache, covering every distinction
    /// the key encodes: bytes, bundle identity, URL, and cross-case identity.
    nonisolated static let unequalPairs: [(RiveSource, RiveSource)] = [
        // Same identifier, different bytes: the identifier alone is not the key.
        (.data(bytes, identifier: "same"), .data(Data([0x00]), identifier: "same")),
        // Different URLs.
        (.url(URL(string: "https://a.example/robot.riv")!), .url(URL(string: "https://b.example/robot.riv")!)),
        // Cross-case: equal-looking names in different cases never collide.
        (.bundle("x"), .data(bytes, identifier: "x")),
        (.bundle("x"), .url(URL(fileURLWithPath: "/x.riv"))),
        (.url(URL(string: "https://example.com/x.riv")!), .data(bytes, identifier: "https://example.com/x.riv")),
    ]

    @Test(arguments: unequalPairs) func distinctSourcesAreUnequal(_ pair: (RiveSource, RiveSource)) {
        #expect(pair.0 != pair.1, "\(pair.0.debugName) must not collide with \(pair.1.debugName)")
    }

    // Not in `unequalPairs` because `Bundle.module` is main-actor isolated
    // under the test target's default isolation.
    @Test func sameResourceNameInDifferentBundlesIsUnequal() {
        #expect(RiveSource.bundle("robot", in: .main) != RiveSource.bundle("robot", in: .module))
    }
}

struct RiveAlignmentTests {
    /// The nine direct SwiftUI-to-Rive alignment mappings.
    nonisolated static let directMappings: [(SwiftUI.Alignment, RiveAlignment)] = [
        (.topLeading, .topLeading), (.top, .top), (.topTrailing, .topTrailing),
        (.leading, .leading), (.center, .center), (.trailing, .trailing),
        (.bottomLeading, .bottomLeading), (.bottom, .bottom), (.bottomTrailing, .bottomTrailing),
    ]

    @Test(arguments: directMappings) func swiftUIAlignmentMapsDirectly(_ pair: (SwiftUI.Alignment, RiveAlignment)) {
        #expect(RiveAlignment(pair.0) == pair.1)
    }

    @Test func baselineAlignmentsFallBackToCenter() {
        // Text-baseline alignments have no Rive counterpart.
        #expect(RiveAlignment(.centerFirstTextBaseline) == .center)
        #expect(RiveAlignment(.leadingLastTextBaseline) == .center)
    }
}

struct RiveFitTests {
    @Test func factoryDefaultsMatchStaticValues() {
        #expect(RiveFit.contain == RiveFit.contain(alignment: .center))
        #expect(RiveFit.actualSize == RiveFit.actualSize(alignment: .center))
    }

    @Test func distinctFitsAreNotEqual() {
        #expect(RiveFit.contain != RiveFit.cover)
        #expect(RiveFit.contain(alignment: .topLeading) != RiveFit.contain(alignment: .center))
        #expect(RiveFit.layout(scale: .automatic) != RiveFit.layout(scale: .fixed(2)))
    }

    @Test func allEightFitModesArePairwiseDistinct() {
        let fits: [RiveFit] = [
            .contain, .cover, .fill, .fitWidth, .fitHeight, .scaleDown, .actualSize, .layout(),
        ]
        for (i, a) in fits.enumerated() {
            for b in fits[fits.index(after: i)...] {
                #expect(a != b, "fit modes \(a) and \(b) must be distinct")
            }
        }
        #expect(Set(fits).count == fits.count)
    }

    @Test func layoutScaleEqualityFollowsItsValue() {
        #expect(RiveLayoutScale.fixed(2) == RiveLayoutScale.fixed(2))
        #expect(RiveLayoutScale.fixed(2) != RiveLayoutScale.fixed(3))
        #expect(RiveLayoutScale.automatic != RiveLayoutScale.fixed(1))
    }
}
