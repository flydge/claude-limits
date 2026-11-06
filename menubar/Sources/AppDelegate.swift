import AppKit

// Menu bar item: two rings from ~/.claude/limits.json, details in the menu.
// Beside it, SystemItem shows memory and disk, and AttentionItem the sessions waiting on the person.

/// macOS puts a status item that has no saved position at the far left of the menu bar, which on a Mac with a
/// notch and many menu bar apps is under the notch, where it is hidden. Until the person moves them (⌘-drag),
/// our three items start at the left end of the system's own items, in the order limits, memory and disk,
/// bell. The number only orders the items: a higher one sits further left; the system's items use 93 to ~400.
/// AppKit forgets the position of an item that is hidden, so the bell asks again each time it is shown.
func seedStatusItemPosition(_ name: String) {
    let positions = ["claude-limits.limits": 410.0, "claude-limits.system": 430.0, "claude-limits.attention": 440.0]
    let key = "NSStatusItem Preferred Position \(name)"
    guard let position = positions[name], UserDefaults.standard.object(forKey: key) == nil else { return }
    UserDefaults.standard.set(position, forKey: key)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var system: SystemItem?
    private var attention: AttentionItem?
    private let lang = Lang.resolve(override: ProcessInfo.processInfo.environment["CLAUDE_LIMITS_LANG"],
                                    preferred: Locale.preferredLanguages)
    private let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_FILE"] ?? "~/.claude/limits.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The default names (Item-0, Item-1…) are the same in every app and macOS remembers a position by name,
        // so after a relaunch the rings could land under the notch. A name of our own keeps them where they were.
        seedStatusItemPosition("claude-limits.limits")
        statusItem.autosaveName = "claude-limits.limits"
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = Strings.of(lang).tooltip
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        // The digits are drawn in labelColor: redraw at once when the theme flips.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(tick), name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)
        system = SystemItem(lang: lang)
        system?.start()
        attention = AttentionItem(lang: lang)
        attention?.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func tick() {
        refresh()
    }

    private func refresh() {
        let snapshot = (try? Data(contentsOf: fileURL)).flatMap(parseSnapshot)
        let now = Date().timeIntervalSince1970
        let five = ringState(snapshot?.fiveHour, updatedAt: snapshot?.updatedAt, now: now)
        let week = ringState(snapshot?.sevenDay, updatedAt: snapshot?.updatedAt, now: now)
        // A plan without a 5-hour limit reports only the week: one ring, no empty slot.
        statusItem.button?.image = hasFiveHour(snapshot) ? RingIcon.image(five, week) : RingIcon.image(week)
        rebuildMenu(snapshot, five: five, week: week, now: now)
    }

    private func rebuildMenu(_ snapshot: Snapshot?, five: RingState, week: RingState, now: TimeInterval) {
        let calendar = Calendar.current
        let text = Strings.of(lang)
        menu.removeAllItems()

        if hasFiveHour(snapshot) {
            menu.addItem(windowItem(windowLine(title: text.fiveHours, snapshot?.fiveHour, now: now, calendar: calendar, lang: lang),
                                    state: five))
        }
        if case .normal = five,
           let line = forecastLine(snapshot?.fiveHour, kind: .fiveHour, now: now, calendar: calendar, lang: lang) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(windowItem(windowLine(title: text.week, snapshot?.sevenDay, now: now, calendar: calendar, lang: lang),
                                state: week))
        if case .normal = week,
           let line = forecastLine(snapshot?.sevenDay, kind: .sevenDay, now: now, calendar: calendar, lang: lang) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(.separator())
        menu.addItem(noteItem(updatedLine(snapshot?.updatedAt, now: now, lang: lang), indented: false))

        let quit = NSMenuItem(title: text.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func windowItem(_ title: String, state: RingState) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: "● ", attributes: [
            .font: font, .foregroundColor: RingIcon.color(for: state),
        ])
        text.append(NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = text
        return item
    }

    private func noteItem(_ title: String, indented: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.indentationLevel = indented ? 1 : 0
        return item
    }
}
