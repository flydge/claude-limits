import AppKit
import UserNotifications

// Second menu bar item: memory and disk rings, details and the apps using the most
// memory in the menu, a notification when either falls into red. Each reading also
// goes to ~/.claude/system.json, which the desktop mod draws above the prompt.

final class SystemItem: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lang: Lang
    private var timer: Timer?
    private var memory: MemoryReading?
    private var disk: DiskReading?
    private var lastLevel: [String: Level] = [:]
    private var lastAlert: [String: TimeInterval] = [:]
    private var top: [ProcessGroup] = []
    private let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["CLAUDE_SYSTEM_FILE"] ?? "~/.claude/system.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    init(lang: Lang) {
        self.lang = lang
        super.init()
    }

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = SystemStrings.of(lang).tooltip
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(tick), name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuildMenu(top: top)
    }

    @objc private func tick() {
        refresh()
    }

    private func refresh() {
        memory = SystemProbe.memory()
        disk = SystemProbe.disk()
        top = groupProcesses(SystemProbe.processes(), limit: 7)
        let json = systemJSON(memory: memory, disk: disk, top: top, updatedAt: Date().timeIntervalSince1970)
        try? Data((json + "\n").utf8).write(to: fileURL, options: .atomic)
        statusItem.button?.image = RingIcon.systemImage(memory: memoryRing(memory), disk: diskRing(disk))
        let text = SystemStrings.of(lang)
        if let memory {
            alertIfNeeded("memory", memoryLevel(memory), title: text.memoryAlert, body: memoryLine(memory, lang: lang))
        }
        if let disk {
            alertIfNeeded("disk", diskLevel(disk), title: text.diskAlert, body: diskLine(disk, lang: lang))
        }
    }

    private func alertIfNeeded(_ key: String, _ level: Level, title: String, body: String) {
        let now = Date().timeIntervalSince1970
        defer { lastLevel[key] = level }
        guard shouldAlert(previous: lastLevel[key], current: level, lastAlert: lastAlert[key], now: now) else { return }
        lastAlert[key] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    private func rebuildMenu(top: [ProcessGroup]) {
        let text = SystemStrings.of(lang)
        menu.removeAllItems()

        menu.addItem(stateItem(memoryLine(memory, lang: lang), state: memoryRing(memory)))
        if let memory {
            menu.addItem(noteItem(memoryDetailLine(memory, lang: lang), indented: true))
            if memoryLevel(memory) == .danger { menu.addItem(noteItem(text.memoryHint, indented: true)) }
        }
        menu.addItem(stateItem(diskLine(disk, lang: lang), state: diskRing(disk)))
        if let disk, diskLevel(disk) == .danger { menu.addItem(noteItem(text.diskHint, indented: true)) }

        if !top.isEmpty {
            menu.addItem(.separator())
            menu.addItem(noteItem(text.top, indented: false))
            for group in top { menu.addItem(noteItem(processLine(group, lang: lang), indented: true)) }
        }

        menu.addItem(.separator())
        let monitor = NSMenuItem(title: text.activityMonitor, action: #selector(openActivityMonitor), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    private func stateItem(_ title: String, state: RingState) -> NSMenuItem {
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
