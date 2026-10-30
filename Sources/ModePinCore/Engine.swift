import Foundation

/// What ModePin sees on one connected display.
public struct DisplayReport {
    public enum State: Equatable {
        /// No profile: ModePin leaves this display alone.
        case unmanaged
        /// Has a profile, but it's switched off or has no modes.
        case off
        /// The override with the added modes is in use.
        case active
        /// The override still needs to be (re)applied.
        case pending
        case failed(String)
        case unreadable
    }

    public enum Action: Equatable {
        case none, applied, restored
    }

    public let display: AVDisplay
    public let edid: EDID?
    public let profile: Profile?
    public var state: State
    public var action: Action = .none

    public var name: String { profile?.name ?? edid?.name ?? "External Display" }

    /// The display's own EDID on this connection.
    public var originalEDID: EDID? {
        profile?.original ?? edid.map { EDIDBuilder.removingAddedModes(from: $0) ?? $0 }
    }
}

/// Decides, per connected display, whether its EDID override is in place,
/// and applies or removes it.
public final class Engine {
    public let store: ProfileStore

    public init(store: ProfileStore = ProfileStore()) {
        self.store = store
    }

    /// The state of every connected display, without changing anything.
    public func status() -> [DisplayReport] {
        AVDisplay.connected().map(inspect)
    }

    /// Makes every display match its profile. Profiles in `skipping` are only
    /// inspected; the app uses this to stop retrying a display that keeps
    /// refusing the override.
    public func enforce(skipping: Set<UUID> = []) -> [DisplayReport] {
        AVDisplay.connected().map { display in
            var report = inspect(display)
            guard let profile = report.profile else { return report }
            do {
                switch report.state {
                case .pending where !skipping.contains(profile.id):
                    try display.setVirtualEDID(profile.customEDID())
                    report.action = .applied
                    Log.info("\(report.name): applied \(profile.modes.map(\.description).joined(separator: ", "))")
                case .off where report.edid?.data != profile.originalEDID:
                    try display.clearVirtualEDID()
                    report.action = .restored
                    Log.info("\(report.name): restored the original EDID")
                default:
                    break
                }
            } catch {
                report.state = .failed(error.localizedDescription)
                Log.error("\(report.name): \(error.localizedDescription)")
            }
            return report
        }
    }

    private func inspect(_ display: AVDisplay) -> DisplayReport {
        guard let edid = display.currentEDID() else {
            return DisplayReport(display: display, edid: nil, profile: nil, state: .unreadable)
        }
        guard let profile = store.profile(matching: edid) else {
            return DisplayReport(display: display, edid: edid, profile: nil, state: .unmanaged)
        }
        guard profile.enabled, !profile.modes.isEmpty else {
            return DisplayReport(display: display, edid: edid, profile: profile, state: .off)
        }
        do {
            let custom = try profile.customEDID()
            return DisplayReport(display: display, edid: edid, profile: profile, state: custom == edid ? .active : .pending)
        } catch {
            return DisplayReport(display: display, edid: edid, profile: profile, state: .failed(error.localizedDescription))
        }
    }

    // MARK: Editing profiles

    public func addMode(_ mode: DisplayMode, to report: DisplayReport) throws {
        var profile = try existingOrNewProfile(for: report)
        guard !profile.modes.contains(mode) else { throw ModePinError.duplicateMode(mode) }
        guard profile.modes.count < EDIDBuilder.maxModes else { throw ModePinError.tooManyModes(EDIDBuilder.maxModes) }
        profile.modes.append(mode)
        _ = try profile.customEDID()
        try store.upsert(profile)
        Log.info("\(profile.name): added \(mode)")
    }

    public func removeMode(_ mode: DisplayMode, from report: DisplayReport) throws {
        guard var profile = report.profile else { throw ModePinError.notConfigured(report.name) }
        guard profile.modes.contains(mode) else { throw ModePinError.modeNotFound(mode) }
        profile.modes.removeAll { $0 == mode }
        try store.upsert(profile)
        Log.info("\(profile.name): removed \(mode)")
    }

    public func setEnabled(_ enabled: Bool, for report: DisplayReport) throws {
        guard var profile = report.profile else { throw ModePinError.notConfigured(report.name) }
        profile.enabled = enabled
        try store.upsert(profile)
        Log.info("\(profile.name): \(enabled ? "enabled" : "disabled")")
    }

    /// Restores the display's own EDID and deletes its profile.
    public func forget(_ report: DisplayReport) throws {
        guard let profile = report.profile else { throw ModePinError.notConfigured(report.name) }
        if report.edid?.data != profile.originalEDID {
            try report.display.clearVirtualEDID()
        }
        try store.remove(profile)
        Log.info("\(profile.name): forgotten")
    }

    private func existingOrNewProfile(for report: DisplayReport) throws -> Profile {
        if let profile = report.profile { return profile }
        guard let original = report.originalEDID else { throw ModePinError.unreadableEDID(report.name) }
        return Profile(name: original.name ?? "External Display", original: original)
    }
}
