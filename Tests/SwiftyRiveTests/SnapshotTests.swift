import CoreGraphics
import Foundation
import Testing
@testable import SwiftyRive

/// Headless rendering via ``RiveDocument/snapshot(artboard:stateMachine:size:fit:scale:at:)``.
///
/// The fixture's default artboard is authored at 500×500. Snapshots render
/// the file's default state (data binding is not applied), so pixel content
/// is asserted only as "not uniformly blank" via variance.
@Suite(.serialized)
struct SnapshotTests {
    @Test func defaultSnapshotUsesAuthoredSizeAtTwoTimesScale() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let image = try await document.snapshot()

        let authored = try document.artboardSize()
        #expect(image.width == Int(authored.width * 2))
        #expect(image.height == Int(authored.height * 2))
        #expect(try #require(Self.pixelVariance(of: image)) > 0)
    }

    @Test func explicitSizeAndScaleControlPixelDimensions() async throws {
        let document = try await Fixtures.dataBindingDocument()

        let image = try await document.snapshot(size: CGSize(width: 200, height: 100), scale: 1)
        #expect(image.width == 200)
        #expect(image.height == 100)

        let retina = try await document.snapshot(size: CGSize(width: 200, height: 100), scale: 3)
        #expect(retina.width == 600)
        #expect(retina.height == 300)
    }

    @Test func fitAffectsRenderingNotDimensions() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let size = CGSize(width: 300, height: 150)

        let contained = try await document.snapshot(size: size, fit: .contain)
        let covered = try await document.snapshot(size: size, fit: .cover)
        #expect(contained.width == 600 && contained.height == 300)
        #expect(covered.width == 600 && covered.height == 300)

        // A 500×500 artboard contained in a wide rect leaves empty side
        // margins; cover crops instead, so the two frames must differ.
        #expect(Self.pixelBytes(of: contained) != Self.pixelBytes(of: covered))
    }

    @Test func advancingTimeIsAccepted() async throws {
        let document = try await Fixtures.dataBindingDocument()
        let image = try await document.snapshot(at: 0.5)
        #expect(image.width == 1000)
        #expect(try #require(Self.pixelVariance(of: image)) > 0)
    }

    @Test func unknownArtboardThrows() async throws {
        let document = try await Fixtures.dataBindingDocument()
        await expectArtboardNotFound(name: "Nope", available: document.artboardNames) {
            _ = try await document.snapshot(artboard: "Nope")
        }
    }

    @Test func unknownStateMachineThrows() async throws {
        let document = try await Fixtures.dataBindingDocument()
        do {
            _ = try await document.snapshot(stateMachine: "Nope")
            Issue.record("Expected stateMachineNotFound to be thrown")
        } catch let RiveLoadError.stateMachineNotFound(name, artboard) {
            #expect(name == "Nope")
            #expect(artboard == nil)
        } catch {
            Issue.record("Expected stateMachineNotFound, got \(error)")
        }
    }

    @Test func invalidScaleThrows() async throws {
        let document = try await Fixtures.dataBindingDocument()
        await #expect(throws: RiveLoadError.self) {
            _ = try await document.snapshot(scale: 0)
        }
    }

    // MARK: - Pixel helpers

    /// Sampled variance of the raw pixel bytes; > 0 means not uniformly blank.
    static func pixelVariance(of image: CGImage) -> Double? {
        guard let data = pixelBytes(of: image) else { return nil }
        var sum = 0.0, sumOfSquares = 0.0
        let count = data.count
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: count, by: 97) {
                let value = Double(buffer[index])
                sum += value
                sumOfSquares += value * value
            }
        }
        let samples = Double((count + 96) / 97)
        let mean = sum / samples
        return sumOfSquares / samples - mean * mean
    }

    static func pixelBytes(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
