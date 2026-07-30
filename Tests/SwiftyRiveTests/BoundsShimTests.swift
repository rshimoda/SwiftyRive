import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import SwiftyRive

@Suite("Bounds shim")
struct BoundsShimTests {
    /// Loads a fresh document directly (bypassing the engine cache) so the
    /// per-document legacy parse counter starts at zero deterministically.
    private func makeDocument() async throws -> RiveDocument {
        let data = try Fixtures.data(named: "data_binding_test")
        return try await RiveDocument(source: .data(data, identifier: "bounds.\(UUID().uuidString)"))
    }

    @Test func defaultArtboardSizeIsTheAuthoredSize() async throws {
        let document = try await makeDocument()
        // The fixture's single artboard is authored at 500x500; hardcoded as
        // a regression anchor.
        #expect(try document.artboardSize() == CGSize(width: 500, height: 500))
    }

    @Test func namedArtboardSizeMatchesTheDefaultArtboard() async throws {
        let document = try await makeDocument()
        #expect(document.artboardNames == ["Artboard"])
        #expect(try document.artboardSize(named: "Artboard") == CGSize(width: 500, height: 500))
    }

    @Test func aspectRatioIsConsistentWithTheSize() async throws {
        let document = try await makeDocument()
        let size = try document.artboardSize()
        #expect(try document.artboardAspectRatio() == size.width / size.height)
        #expect(try document.artboardAspectRatio(named: "Artboard") == 1)
    }

    @Test func unknownArtboardThrowsWithAvailableNames() async throws {
        let document = try await makeDocument()
        do {
            _ = try document.artboardSize(named: "Missing")
            Issue.record("Expected artboardNotFound to be thrown")
        } catch let RiveLoadError.artboardNotFound(name, available) {
            #expect(name == "Missing")
            #expect(available == ["Artboard"])
        }
    }

    @Test func corruptDataThrowsAParseError() async throws {
        let corrupt = try Fixtures.data(named: "corrupt")
        do {
            _ = try LegacyArtboardBounds.readCatalog(from: corrupt)
            Issue.record("Expected parseFailed to be thrown")
        } catch RiveLoadError.parseFailed {
            // Expected.
        }
    }

    @Test func repeatedCallsHitTheDocumentCache() async throws {
        let document = try await makeDocument()
        // The fire-and-forget prewarm may or may not have run yet, but a
        // parse must never happen more than once.
        #expect(document.legacyBoundsParseCount <= 1)

        let first = try document.artboardSize()
        let second = try document.artboardSize()
        _ = try document.artboardSize(named: "Artboard")
        _ = try document.artboardAspectRatio()

        #expect(first == second)
        #expect(document.legacyBoundsParseCount == 1)
    }

    @Test func boundsCatalogPrewarmsWithoutASizingCall() async throws {
        let document = try await makeDocument()

        // The prewarm is fire-and-forget at utility priority; give it a
        // bounded window to run without ever calling artboardSize().
        let deadline = ContinuousClock.now + .seconds(5)
        while document.legacyBoundsParseCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(document.legacyBoundsParseCount == 1)

        // The sizing call is now a pure cache hit.
        #expect(try document.artboardSize() == CGSize(width: 500, height: 500))
        #expect(document.legacyBoundsParseCount == 1)
    }
}

@Suite("Natural size proposal resolution")
struct NaturalSizeResolutionTests {
    private let natural = CGSize(width: 400, height: 200)

    @Test func bothAxesUnspecifiedReturnsTheNaturalSize() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: nil, height: nil),
            natural: natural
        )
        #expect(resolved == natural)
    }

    @Test func proposedWidthDerivesHeightFromAspectRatio() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: 100, height: nil),
            natural: natural
        )
        #expect(resolved == CGSize(width: 100, height: 50))
    }

    @Test func proposedHeightDerivesWidthFromAspectRatio() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: nil, height: 100),
            natural: natural
        )
        #expect(resolved == CGSize(width: 200, height: 100))
    }

    @Test func bothAxesProposedReturnsTheProposal() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: 123, height: 45),
            natural: natural
        )
        #expect(resolved == CGSize(width: 123, height: 45))
    }

    @Test func infiniteProposalCountsAsUnspecified() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: .infinity, height: .infinity),
            natural: natural
        )
        #expect(resolved == natural)
    }

    @Test func degenerateNaturalSizeFallsBackToGreedySizing() {
        let resolved = RiveRepresentable.resolveNaturalSize(
            proposal: ProposedViewSize(width: 100, height: nil),
            natural: .zero
        )
        #expect(resolved == nil)
    }
}
