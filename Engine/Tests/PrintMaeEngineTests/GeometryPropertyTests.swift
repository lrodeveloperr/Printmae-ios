import XCTest
import CoreGraphics
@testable import PrintMaeEngine

final class GeometryPropertyTests: XCTestCase {
    func testTenThousandAspectFitSequences() throws {
        var rng = TestLCG(seed: 250_925)
        for _ in 0 ..< 10_000 {
            let source = CGSize(width: rng.next(in: 0.01 ... 10_000), height: rng.next(in: 0.01 ... 10_000))
            let destination = CGRect(
                x: rng.next(in: -2_000 ... 2_000),
                y: rng.next(in: -2_000 ... 2_000),
                width: rng.next(in: 0.01 ... 2_000),
                height: rng.next(in: 0.01 ... 2_000)
            )
            let actual = try PrintGeometry.centredAspectFitRect(source: source, destination: destination)
            XCTAssertTrue(destination.insetBy(dx: -0.000_001, dy: -0.000_001).contains(actual))
            XCTAssertEqual(actual.midX, destination.midX, accuracy: 0.000_001)
            XCTAssertEqual(actual.midY, destination.midY, accuracy: 0.000_001)
            XCTAssertEqual(actual.width / actual.height, source.width / source.height, accuracy: 0.000_001)
        }
    }

    func testRejectsNonPositiveOrNonFiniteGeometry() {
        let destination = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertThrowsError(try PrintGeometry.aspectFitScale(source: .zero, destination: destination))
        XCTAssertThrowsError(
            try PrintGeometry.aspectFitScale(
                source: CGSize(width: CGFloat.infinity, height: 1),
                destination: destination
            )
        )
        XCTAssertThrowsError(
            try PrintGeometry.aspectFitScale(
                source: CGSize(width: 1, height: 1),
                destination: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)
            )
        )
    }

    func testFourQuarterTurnsReturnOriginalSize() throws {
        let original = CGSize(width: 123.5, height: 456.75)
        var actual = original
        for _ in 0 ..< 4 {
            actual = try PrintGeometry.rotatedSize(actual, quarterTurnsClockwise: 1)
        }
        XCTAssertEqual(actual, original)
    }

    func testPaperDimensionsUseExactMillimetreConversion() {
        XCTAssertEqual(PaperSpec.a4Portrait.points.width, 210.0 / 25.4 * 72.0, accuracy: 0.000_001)
        XCTAssertEqual(PaperSpec.a4Portrait.points.height, 297.0 / 25.4 * 72.0, accuracy: 0.000_001)
    }
}

private struct TestLCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Double(state >> 11) / Double(UInt64.max >> 11)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
