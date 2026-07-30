import Foundation
import Testing
@testable import SwiftyRive

struct RiveSourceTests {
    @Test func identicalBundleSourcesAreEqual() {
        #expect(RiveSource.bundle("robot") == RiveSource.bundle("robot"))
        #expect(RiveSource.bundle("robot") != RiveSource.bundle("hero"))
    }

    @Test func dataSourcesAreKeyedByIdentifierAndBytes() {
        let data = Data([0x52, 0x49, 0x56, 0x45])
        #expect(RiveSource.data(data, identifier: "a") == RiveSource.data(data, identifier: "a"))
        #expect(RiveSource.data(data, identifier: "a") != RiveSource.data(data, identifier: "b"))
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
}
