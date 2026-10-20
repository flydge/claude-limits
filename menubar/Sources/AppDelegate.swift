import AppKit

// Menu bar item: two rings from ~/.claude/limits.json, details in the menu.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_FILE"] ?? "~/.claude/limits.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Лимиты Claude: 5 часов и неделя"
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        // The digits are drawn in labelColor: redraw at once when the theme flips.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(tick), name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)
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
        statusItem.button?.image = RingIcon.image(five, week)
        rebuildMenu(snapshot, five: five, week: week, now: now)
    }

    private func rebuildMenu(_ snapshot: Snapshot?, five: RingState, week: RingState, now: TimeInterval) {
        let calendar = Calendar.current
        menu.removeAllItems()

        menu.addItem(windowItem(windowLine(title: "5 часов", snapshot?.fiveHour, now: now, calendar: calendar),
                                state: five))
        if case .normal = five,
           let line = forecastLine(snapshot?.fiveHour, kind: .fiveHour, now: now, calendar: calendar) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(windowItem(windowLine(title: "Неделя", snapshot?.sevenDay, now: now, calendar: calendar),
                                state: week))
        if case .normal = week,
           let line = forecastLine(snapshot?.sevenDay, kind: .sevenDay, now: now, calendar: calendar) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(.separator())
        menu.addItem(noteItem(updatedLine(snapshot?.updatedAt, now: now), indented: false))

        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
