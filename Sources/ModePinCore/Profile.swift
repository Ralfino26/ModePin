import Foundation

/// The extra modes for one display on one kind of connection.
///
/// A profile is tied to the exact EDID the display reports (`originalEDID`),
/// not just to the monitor model: the same monitor reports a different EDID
/// through a dock than on a direct HDMI 2.1 port, and an override built for
/// the dock must never replace the richer direct-connection EDID.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var originalEDID: Data
    public var modes: [DisplayMode]
    public var enabled: Bool
    /// The mode to select after the override is applied, i.e. after the display
    /// (re)connects. macOS often keeps the resolution it picked from the
    /// original EDID otherwise. nil leaves the choice to macOS.
    public var preferredMode: DisplayMode?

    public init(name: String, original: EDID, modes: [DisplayMode] = []) {
        id = UUID()
        self.name = name
        originalEDID = original.data
        self.modes = modes
        enabled = true
        preferredMode = modes.first
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, originalEDID, modes, enabled, preferredMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        originalEDID = try c.decode(Data.self, forKey: .originalEDID)
        modes = try c.decode([DisplayMode].self, forKey: .modes)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        // Profiles from 1.0.0 have no key: switch to the first added mode.
        // An explicit null means "leave it to macOS".
        preferredMode = c.contains(.preferredMode) ? try c.decodeIfPresent(DisplayMode.self, forKey: .preferredMode) : modes.first
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(originalEDID, forKey: .originalEDID)
        try c.encode(modes, forKey: .modes)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(preferredMode, forKey: .preferredMode)
    }

    public var original: EDID? { EDID(originalEDID) }

    public func customEDID() throws -> EDID {
        guard let original else { throw ModePinError.unsupportedEDID }
        return try EDIDBuilder.adding(modes, to: original)
    }

    /// True for the display's own EDID and for any override ModePin built from it,
    /// including one from before the mode list last changed.
    public func matches(_ edid: EDID) -> Bool {
        edid.data == originalEDID || EDIDBuilder.removingAddedModes(from: edid)?.data == originalEDID
    }
}

/// Profiles on disk: ~/Library/Application Support/ModePin/profiles.json.
public final class ProfileStore {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ModePin/profiles.json")

    public private(set) var profiles: [Profile] = []
    private let url: URL

    public init(url: URL = ProfileStore.defaultURL) {
        self.url = url
        reload()
    }

    public func reload() {
        guard let data = try? Data(contentsOf: url) else { profiles = []; return }
        do {
            profiles = try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            Log.error("Couldn't read \(url.path): \(error.localizedDescription)")
        }
    }

    public func profile(matching edid: EDID) -> Profile? {
        profiles.first { $0.matches(edid) }
    }

    public func upsert(_ profile: Profile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try save()
    }

    public func remove(_ profile: Profile) throws {
        profiles.removeAll { $0.id == profile.id }
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(profiles).write(to: url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            ModePin.profilesChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
