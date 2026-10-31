import AppKit
import IOKit
import ModePinCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// A display that hasn't taken the override after this many tries is left
    /// alone until it's reconnected, its settings change or you choose
    /// Re-apply Now, so a refusing display never flickers in a loop.
    private static let maxAttempts = 3
    /// Cheap safety net: reading EDIDs doesn't touch the display.
    private static let pollInterval: TimeInterval = 60

    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private var pendingCheck: DispatchWorkItem?
    private var pollTimer: Timer?
    private var notificationPort: IONotificationPortRef?
    private var attempts: [UUID: Int] = [:]
    /// Profiles whose preferred mode should be selected once the override is
    /// live, with the number of checks spent waiting for the mode to appear.
    private var pendingModeSwitch: [UUID: Int] = [:]
    private static let maxModeSwitchChecks = 10
    /// Checks in a row that found the override in place but none of its modes
    /// offered by macOS. That happens when the display renegotiates while it's
    /// waking up; only a fresh apply fixes it.
    private var missingModeChecks: [UUID: Int] = [:]
    private static let maxMissingModeChecks = 3
    /// Set between the screens going to sleep and waking. ModePin never touches
    /// a display then: an override applied to a sleeping or half-awake display
    /// can stick without macOS ever offering its modes.
    private var screensAsleep = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running = LoginItem.otherInstances().first {
            Log.info("Already running (pid \(running.processIdentifier)); exiting")
            exit(0)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(failed: false)

        observeDisplayChanges()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            defaults.set(true, forKey: "didSetUpLoginItem")
            try? LoginItem.enable()
        }

        Log.info("ModePin \(ModePin.version) started")
        check(after: 0)
    }

    // MARK: Watching for displays

    private func observeDisplayChanges() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.check(after: 1.5)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.screensAsleep = true
                self.pendingCheck?.cancel()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                if notification.name != NSWorkspace.sessionDidBecomeActiveNotification {
                    self.screensAsleep = false
                }
                // Waking drops the override like a reconnect does, so each wake gets fresh attempts.
                self.attempts.removeAll()
                self.missingModeChecks.removeAll()
                self.check(after: 2)
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: ModePin.profilesChangedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.engine.store.reload()
            self.attempts.removeAll()
            // A settings change (including a new preferred mode) re-selects the preferred mode.
            for profile in self.engine.store.profiles { self.pendingModeSwitch[profile.id] = 0 }
            self.check(after: 0.2)
        }
        distributed.addObserver(forName: ModePin.quitNotification, object: nil, queue: .main) { _ in
            NSApp.terminate(nil)
        }

        // Display connect/disconnect at the IOKit level: this fires for a dock
        // being replugged even before macOS reconfigures its screens.
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        notificationPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            drain(iterator)
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().displayServicesChanged()
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching(AVDisplay.serviceClass), callback, context, &iterator)
            drain(iterator)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.check(after: 0)
        }
    }

    private func displayServicesChanged() {
        attempts.removeAll()
        missingModeChecks.removeAll()
        check(after: 1.5)
    }

    /// The screens are on and the Mac is fully awake (not in dark wake).
    private var displaysAwake: Bool {
        !screensAsleep && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    /// Coalesces bursts of events (a replug fires several) into one check.
    private func check(after delay: TimeInterval) {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforce() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enforce() {
        // Waking up comes back here through screensDidWake.
        guard displaysAwake else { return }

        let exhausted = Set(attempts.filter { $0.value >= Self.maxAttempts }.keys)

        let reports = engine.enforce(skipping: exhausted)
        var followUp: TimeInterval?
        func checkAgain(after delay: TimeInterval) { followUp = min(followUp ?? delay, delay) }

        for report in reports {
            guard let profile = report.profile, let edid = report.edid else { continue }
            let id = profile.id
            switch (report.state, report.action) {
            case (_, .applied):
                attempts[id, default: 0] += 1
                missingModeChecks[id] = nil
                pendingModeSwitch[id] = 0
                // Confirm the display came back with the new EDID; retry if it didn't.
                checkAgain(after: 6)
            case (.active, _):
                if pendingModeSwitch[id] != nil {
                    if !selectPreferredMode(report) { checkAgain(after: 2) }
                    continue
                }
                switch ScreenModes.offersAny(of: profile.modes, on: edid) {
                case true?:
                    attempts[id] = nil
                    missingModeChecks[id] = nil
                case false?:
                    let checks = missingModeChecks[id, default: 0] + 1
                    missingModeChecks[id] = checks
                    if checks >= Self.maxMissingModeChecks {
                        if reapplyFromScratch(report) { checkAgain(after: 3) }
                    } else {
                        checkAgain(after: 2)
                    }
                case nil:
                    // Offline or asleep: the wake notifications and the poll come back to it.
                    break
                }
            case (.off, _):
                attempts[id] = nil
                missingModeChecks[id] = nil
                pendingModeSwitch[id] = nil
            case (.pending, .none) where attempts[id] == Self.maxAttempts:
                logGiveUp(report)
            default:
                break
            }
        }
        updateIcon(failed: reports.contains(where: isFailure))
        if let followUp { check(after: followUp) }
    }

    /// The override is in place but macOS never offered its modes. Removing it
    /// makes the next check apply it again, which renegotiates the link like a
    /// replug. Returns false once the attempts for this connection are used up.
    private func reapplyFromScratch(_ report: DisplayReport) -> Bool {
        guard let id = report.profile?.id else { return false }
        missingModeChecks[id] = nil
        guard attempts[id, default: 0] < Self.maxAttempts else {
            if attempts[id] == Self.maxAttempts { logGiveUp(report) }
            return false
        }
        Log.info("\(report.name): macOS isn't offering the added modes; re-applying from scratch")
        do {
            try report.display.clearVirtualEDID()
            return true
        } catch {
            Log.error("\(report.name): \(error.localizedDescription)")
            return false
        }
    }

    private func logGiveUp(_ report: DisplayReport) {
        guard let id = report.profile?.id else { return }
        // Counting past the limit makes this log once, not every poll.
        attempts[id] = Self.maxAttempts + 1
        Log.error("\(report.name): gave up after \(Self.maxAttempts) attempts; reconnect the display or choose Re-apply Now")
    }

    /// Selects the profile's preferred mode after an apply. Returns false while
    /// it should be tried again (the mode isn't listed yet).
    private func selectPreferredMode(_ report: DisplayReport) -> Bool {
        guard let profile = report.profile, let edid = report.edid else { return true }
        guard let mode = profile.preferredMode else {
            pendingModeSwitch[profile.id] = nil
            return true
        }
        switch ScreenModes.select(mode, on: edid) {
        case .switched:
            Log.info("\(report.name): switched to \(mode)")
            attempts[profile.id] = nil
        case .alreadyCurrent:
            attempts[profile.id] = nil
        case .notReady:
            let checks = (pendingModeSwitch[profile.id] ?? 0) + 1
            guard checks >= Self.maxModeSwitchChecks else {
                pendingModeSwitch[profile.id] = checks
                return false
            }
            // The next checks notice the missing mode and re-apply from scratch.
            Log.error("\(report.name): \(mode) didn't show up in the display's mode list")
            pendingModeSwitch[profile.id] = nil
            return false
        case .failed(let code):
            Log.error("\(report.name): switching to \(mode) failed (CGError \(code))")
        }
        pendingModeSwitch[profile.id] = nil
        return true
    }

    private func gaveUp(_ report: DisplayReport) -> Bool {
        report.profile.map { (attempts[$0.id] ?? 0) >= Self.maxAttempts } ?? false
    }

    private func isFailure(_ report: DisplayReport) -> Bool {
        if case .failed = report.state { return true }
        return (report.state == .pending || report.state == .active) && gaveUp(report)
    }

    // MARK: Menu

    private func updateIcon(failed: Bool) {
        let name = failed ? "exclamationmark.triangle" : "display"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ModePin")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = failed ? "ModePin: a display didn't accept its added modes" : "ModePin"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let reports = engine.status()

        let header = NSMenuItem(title: "ModePin", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "ModePin", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(header)
        menu.addItem(.separator())

        if reports.isEmpty {
            menu.addItem(disabled("No external displays"))
        }
        for report in reports {
            menu.addItem(displayItem(for: report))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Re-apply Now", #selector(reapply), key: "r"))
        let login = menuItem("Start at Login", #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(menuItem("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit ModePin", #selector(quit), key: "q"))
    }

    private func displayItem(for report: DisplayReport) -> NSMenuItem {
        let (summary, symbol, color) = summarize(report)
        let item = NSMenuItem(title: report.name, action: nil, keyEquivalent: "")
        item.image = statusImage(symbol, color)
        if #available(macOS 14.4, *) { item.subtitle = summary }

        let submenu = NSMenu()
        if #unavailable(macOS 14.4) { submenu.addItem(disabled(summary)) }
        if let limit = report.originalEDID?.maxPixelClockMHz {
            submenu.addItem(disabled("Connection limit: \(limit) MHz"))
        }
        submenu.addItem(.separator())

        if let profile = report.profile {
            for mode in profile.modes {
                let modeItem = NSMenuItem(title: mode.description, action: nil, keyEquivalent: "")
                modeItem.state = profile.preferredMode == mode ? .on : .off
                let modeMenu = NSMenu()
                let prefer = menuItem("Switch to This After Connecting", #selector(togglePreferredMode(_:)),
                                      represented: Pick(report: report, mode: mode))
                prefer.state = profile.preferredMode == mode ? .on : .off
                modeMenu.addItem(prefer)
                modeMenu.addItem(.separator())
                modeMenu.addItem(menuItem("Remove", #selector(removeMode(_:)), represented: Pick(report: report, mode: mode)))
                modeItem.submenu = modeMenu
                submenu.addItem(modeItem)
            }
        }
        submenu.addItem(menuItem("Add Mode…", #selector(addMode(_:)), represented: Pick(report: report)))

        if let profile = report.profile {
            submenu.addItem(.separator())
            let enabled = menuItem("Enabled", #selector(toggleEnabled(_:)), represented: Pick(report: report))
            enabled.state = profile.enabled ? .on : .off
            submenu.addItem(enabled)
            submenu.addItem(menuItem("Forget This Display…", #selector(forget(_:)), represented: Pick(report: report)))
        }
        item.submenu = submenu
        return item
    }

    private func summarize(_ report: DisplayReport) -> (String, String, NSColor) {
        let modes = report.profile?.modes.map(\.description).joined(separator: ", ") ?? ""
        let gaveUp = gaveUp(report)
        switch report.state {
        case .active where gaveUp: return ("macOS isn't offering \(modes)", "exclamationmark.triangle.fill", .systemOrange)
        case .active: return ("\(modes) active", "checkmark.circle.fill", .systemGreen)
        case .pending where gaveUp: return ("Display didn't accept \(modes)", "exclamationmark.triangle.fill", .systemOrange)
        case .pending: return ("Applying \(modes)…", "arrow.triangle.2.circlepath", .systemBlue)
        case .off: return ("Off", "pause.circle", .secondaryLabelColor)
        case .unmanaged: return ("No added modes", "circle.dashed", .secondaryLabelColor)
        case .failed(let message): return (message, "exclamationmark.triangle.fill", .systemOrange)
        case .unreadable: return ("EDID unreadable", "questionmark.circle", .secondaryLabelColor)
        }
    }

    private func statusImage(_ symbol: String, _ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    private struct Pick {
        let report: DisplayReport
        var mode: DisplayMode?
    }

    @objc private func reapply() {
        attempts.removeAll()
        missingModeChecks.removeAll()
        check(after: 0)
    }

    @objc private func addMode(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Add a mode to \(pick.report.name)"
        alert.informativeText = "Enter a resolution and refresh rate. ModePin adds it to what the display reports, using standard reduced-blanking timings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "5120x1440@60"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let mode = DisplayMode(parsing: field.stringValue) else {
            showError("“\(field.stringValue)” isn't a mode. Use width x height @ refresh, for example 5120x1440@60.")
            return
        }
        let needed = mode.reducedBlankingTiming.pixelClockMHz
        if let limit = pick.report.originalEDID?.maxPixelClockMHz, needed > Double(limit) {
            let warning = NSAlert()
            warning.messageText = "\(mode) probably won't work on this connection"
            warning.informativeText = "It needs a \(Int(needed)) MHz pixel clock, and this connection reports a \(limit) MHz limit. Lower the refresh rate or connect the display another way."
            warning.addButton(withTitle: "Cancel")
            warning.addButton(withTitle: "Add Anyway")
            guard warning.runModal() == .alertSecondButtonReturn else { return }
        }
        perform { try engine.addMode(mode, to: pick.report) }
    }

    @objc private func removeMode(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let mode = pick.mode else { return }
        perform { try engine.removeMode(mode, from: pick.report) }
    }

    @objc private func togglePreferredMode(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let mode = pick.mode, let profile = pick.report.profile else { return }
        let newValue = profile.preferredMode == mode ? nil : mode
        perform { try engine.setPreferredMode(newValue, for: pick.report) }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick, let profile = pick.report.profile else { return }
        perform { try engine.setEnabled(!profile.enabled, for: pick.report) }
    }

    @objc private func forget(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget \(pick.report.name)?"
        alert.informativeText = "Its added modes are removed and it goes back to the resolutions it offers by itself."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try engine.forget(pick.report) }
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.isEnabled ? LoginItem.disable() : LoginItem.enable()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            attempts.removeAll()
            check(after: 0.2)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ModePin"
        alert.informativeText = message
        alert.runModal()
    }
}

/// IOKit only re-arms a notification once its iterator has been emptied.
private func drain(_ iterator: io_iterator_t) {
    var entry = IOIteratorNext(iterator)
    while entry != IO_OBJECT_NULL {
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
}
