import XCTest
@testable import ModePinCore

final class EDIDBuilderTests: XCTestCase {
    func testAddsDisplayIDBlock() throws {
        let custom = try EDIDBuilder.adding([DisplayMode(width: 5120, height: 1440, refresh: 60)], to: odysseyThroughDock)
        XCTAssertTrue(custom.hasValidChecksums)
        XCTAssertEqual(custom.extensionCount, 2)
        XCTAssertEqual(Array(custom.bytes[1..<126]), Array(odysseyThroughDock.bytes[1..<126]))
        XCTAssertEqual(custom.block(1), odysseyThroughDock.block(1))

        // DisplayID 1.2, one Type I timing: 469.00 MHz, 32:9, 5120+160 × 1440+41, +hsync −vsync.
        let block = Array(custom.block(2))
        XCTAssertEqual(Array(block.prefix(28)), [
            0x70, 0x12, 0x17, 0x00, 0x00, 0x03, 0x00, 0x14,
            0x33, 0xB7, 0x00, 0x08, 0xFF, 0x13, 0x9F, 0x00, 0x2F, 0x80, 0x1F, 0x00,
            0x9F, 0x05, 0x28, 0x00, 0x02, 0x00, 0x09, 0x00,
        ])
        XCTAssertEqual(block[1...28].reduce(UInt8(0)) { $0 &+ $1 }, 0, "DisplayID section checksum")
    }

    func testRoundTrip() throws {
        let modes = [DisplayMode(width: 5120, height: 1440, refresh: 60), DisplayMode(width: 3840, height: 1080, refresh: 120)]
        let custom = try EDIDBuilder.adding(modes, to: odysseyThroughDock)
        XCTAssertEqual(EDIDBuilder.removingAddedModes(from: custom), odysseyThroughDock)
        XCTAssertNil(EDIDBuilder.removingAddedModes(from: odysseyThroughDock))
    }

    func testModeLimits() {
        let six = (0..<6).map { DisplayMode(width: 5120, height: 1440, refresh: 50 + $0) }
        XCTAssertThrowsError(try EDIDBuilder.adding(six, to: odysseyThroughDock))
        XCTAssertNoThrow(try EDIDBuilder.adding(Array(six.prefix(5)), to: odysseyThroughDock))
        XCTAssertThrowsError(try EDIDBuilder.adding([], to: odysseyThroughDock))
    }

    func testAspectCodes() {
        XCTAssertEqual(EDIDBuilder.aspectCode(DisplayMode(width: 3840, height: 2160, refresh: 60)), 4)
        XCTAssertEqual(EDIDBuilder.aspectCode(DisplayMode(width: 5120, height: 1440, refresh: 60)), 8)
    }
}
