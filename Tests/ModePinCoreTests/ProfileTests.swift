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

    func testPreferredModeDefaultsAndPersistence() throws {
        let mode = DisplayMode(width: 5120, height: 1440, refresh: 60)
        var profile = Profile(name: "Odyssey", original: odysseyThroughDock, modes: [mode])
        XCTAssertEqual(profile.preferredMode, mode)

        // 1.0.0 wrote no preferredMode key: switch to the first added mode.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        legacy.removeValue(forKey: "preferredMode")
        let migrated = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.preferredMode, mode)

        // An explicit "leave it to macOS" survives a round trip.
        profile.preferredMode = nil
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        XCTAssertNil(decoded.preferredMode)
        XCTAssertEqual(decoded, profile)
    }
}
