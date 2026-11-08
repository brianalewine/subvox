import XCTest
@testable import Subvox

final class PassageTests: XCTestCase {
    func testTokenizationPreservesOrderAndRepetitions() {
        XCTAssertEqual(PassageAlignment.words(in: "“Don’t infer,” don't! Re-test."),
                       ["don't", "infer", "don't", "re", "test"])
    }

    func testAlignmentRequiresAnIntactWindowWithInteriorMotion() {
        func samples(active: Range<Int>) -> [MotionSample] {
            (0..<40).map { i in
                MotionSample(t: Double(i) / 25, rotation: (active.contains(i) ? 0.1 : 0.001, 0, 0))
            }
        }
        func aligned(_ window: [MotionSample]) -> Template? {
            PassageAlignment.template(word: "infer", samples: window, from: 0, to: 1.6, threshold: 0.02)
        }
        let good = samples(active: 8..<20)
        XCTAssertEqual(aligned(good)?.samples, Array(good[6...21]))
        XCTAssertNil(aligned(samples(active: 0..<0)))
        XCTAssertNil(aligned(samples(active: 33..<40)))
        XCTAssertNil(aligned(Array(good.prefix(10)) + Array(good.suffix(20))))
    }
}
