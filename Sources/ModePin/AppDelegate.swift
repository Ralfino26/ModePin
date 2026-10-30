import AppKit
import IOKit
import ModePinCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// A display that hasn't taken the override after this many tries in
    /// `retryWindow` is left alone until it's reconnected or you retry.
    private static let maxAttempts = 3
    private static let retryWindow: TimeInterval = 120
    /// Cheap safety net: reading EDIDs doesn't touch the display.
    private static let pollInterval: TimeInterval = 60

    private let engine = Engine()
    private var statusItem: NSStatusItem!
    private var pendingCheck: DispatchWorkItem?
    private var pollTimer: Timer?
    private var notificationPort: IONotificationPortRef?
    private var attempts: [UUID: [Date]] = [:]

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
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.check(after: 2)
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: ModePin.profilesChangedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.store.reload()
            self?.attempts.removeAll()
            self?.check(after: 0.2)
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
        check(after: 1.5)
    }

    /// Coalesces bursts of events (a replug fires several) into one check.
    private func check(after delay: TimeInterval) {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforce() }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enforce() {
        let now = Date()
        attempts = attempts.mapValues { $0.filter { now.timeIntervalSince($0) < Self.retryWindow } }
        let exhausted = Set(attempts.filter { $0.value.count >= Self.maxAttempts }.keys)

        let reports = engine.enforce(skipping: exhausted)
        var needsFollowUp = false
        for report in reports {
            guard let id = report.profile?.id else { continue }
            switch (report.state, report.action) {
            case (_, .applied):
                attempts[id, default: []].append(now)
                needsFollowUp = true
            case (.active, _), (.off, _):
                attempts[id] = nil
            case (.pending, .none) where exhausted.contains(id):
                Log.error("\(report.name): gave up after \(Self.maxAttempts) attempts; reconnect the display or choose Re-apply Now")
            default:
                break
            }
        }
        updateIcon(failed: reports.contains { isFailure($0, exhausted: exhausted) })
        // Confirm the display came back with the new EDID; retry if it didn't.
        if needsFollowUp { check(after: 6) }
    }

    private func isFailure(_ report: DisplayReport, exhausted: Set<UUID>) -> Bool {
        if case .failed = report.state { return true }
        if report.state == .pending, let id = report.profile?.id, exhausted.contains(id) { return true }
        return false
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
                let modeMenu = NSMenu()
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
        let gaveUp = report.profile.map { (attempts[$0.id]?.count ?? 0) >= Self.maxAttempts } ?? false
        switch report.state {
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
