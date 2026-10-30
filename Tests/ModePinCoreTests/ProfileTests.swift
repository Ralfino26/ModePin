import XCTest
@testable import ModePinCore

final class ProfileTests: XCTestCase {
    func testMatchesOriginalAndAnyOverrideBuiltFromIt() throws {
        var profile = Profile(name: "Odyssey", original: odysseyThroughDock, modes: [DisplayMode(width: 5120, height: 1440, refresh: 60)])
        let current = try profile.customEDID()
        XCTAssertTrue(profile.matches(odysseyThroughDock))
        XCTAssertTrue(profile.matches(current))

        profile.modes.append(DisplayMode(width: 3840, height: 1080, refresh: 120))
        XCTAssertTrue(profile.matches(current), "an override from before the mode list changed still belongs to the profile")
        XCTAssertNotEqual(try profile.customEDID(), current)
    }

    func testDoesNotMatchOtherConnections() {
        var direct = odysseyThroughDock.bytes
        direct[131] ^= 0x01  // same monitor, different CTA block (e.g. direct HDMI 2.1)
        let profile = Profile(name: "Odyssey", original: odysseyThroughDock)
        XCTAssertFalse(profile.matches(EDID(EDID.checksummed(direct))!))
    }

    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modepin-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ProfileStore(url: url)
        let profile = Profile(name: "Odyssey", original: odysseyThroughDock, modes: [DisplayMode(width: 5120, height: 1440, refresh: 60)])
        try store.upsert(profile)
        XCTAssertEqual(ProfileStore(url: url).profiles, [profile])
        try store.remove(profile)
        XCTAssertEqual(ProfileStore(url: url).profiles, [])
    }
}
