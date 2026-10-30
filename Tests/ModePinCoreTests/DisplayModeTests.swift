import XCTest
@testable import ModePinCore

final class DisplayModeTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(DisplayMode(parsing: "5120x1440@60"), DisplayMode(width: 5120, height: 1440, refresh: 60))
        XCTAssertEqual(DisplayMode(parsing: "5120 × 1440 @ 120Hz"), DisplayMode(width: 5120, height: 1440, refresh: 120))
        XCTAssertEqual(DisplayMode(parsing: "3440x1440"), DisplayMode(width: 3440, height: 1440, refresh: 60))
        XCTAssertNil(DisplayMode(parsing: "5120"))
        XCTAssertNil(DisplayMode(parsing: "5120x1440@"))
        XCTAssertNil(DisplayMode(parsing: "0x0@60"))
    }

    /// Matches the VESA DMT reduced-blanking timings.
    func testReducedBlankingMatchesVESA() {
        let fhd = DisplayMode(width: 1920, height: 1080, refresh: 60).reducedBlankingTiming
        XCTAssertEqual(fhd.hTotal, 2080)
        XCTAssertEqual(fhd.vTotal, 1111)
        XCTAssertEqual(fhd.pixelClock10kHz, 13850)

        let qhd = DisplayMode(width: 2560, height: 1440, refresh: 60).reducedBlankingTiming
        XCTAssertEqual(qhd.hTotal, 2720)
        XCTAssertEqual(qhd.vTotal, 1481)
        XCTAssertEqual(qhd.pixelClock10kHz, 24150)
    }

    func testSuperUltrawide() {
        let t = DisplayMode(width: 5120, height: 1440, refresh: 60).reducedBlankingTiming
        XCTAssertEqual(t.hTotal, 5280)
        XCTAssertEqual(t.vTotal, 1481)
        XCTAssertEqual(t.vSync, 10)
        XCTAssertEqual(t.pixelClockMHz, 469.0)
        XCTAssertEqual(t.refreshRate, 60, accuracy: 0.05)
    }
}
