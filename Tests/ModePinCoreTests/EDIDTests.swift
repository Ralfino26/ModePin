import XCTest
@testable import ModePinCore

final class EDIDTests: XCTestCase {
    func testParsesIdentity() {
        XCTAssertTrue(odysseyThroughDock.hasValidChecksums)
        XCTAssertEqual(odysseyThroughDock.manufacturer, "SAM")
        XCTAssertEqual(odysseyThroughDock.productCode, 0x73D0)
        XCTAssertEqual(odysseyThroughDock.name, "Odyssey G95NC")
        XCTAssertEqual(odysseyThroughDock.maxPixelClockMHz, 600)
        XCTAssertEqual(odysseyThroughDock.extensionCount, 1)
    }

    func testIgnoresBytesAfterDeclaredBlocks() {
        let padded = EDID(odysseyThroughDock.bytes + [UInt8](repeating: 0xAB, count: 128))
        XCTAssertEqual(padded, odysseyThroughDock)
    }

    func testRejectsGarbage() {
        XCTAssertNil(EDID([UInt8](repeating: 0, count: 128)))
        XCTAssertNil(EDID(odysseyThroughDock.bytes.prefix(200)))
    }
}
