import AppKit
import UserNotifications

// Second menu bar item: CPU, GPU, memory and disk rings, details and the apps using the most
// memory in the menu, a notification when either falls into red. Each reading also
// goes to ~/.claude/system.json, which the desktop mod draws above the prompt.

final class SystemItem: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lang: Lang
    private var timer: Timer?
    private var memory: MemoryReading?
    private var disk: DiskReading?
    private var cpu: Double?
    private var cpuTicks: CPUTicks?
    private var gpu: GPUReading?
    private var queue: QueueReading?
    private var lastLevel: [String: Level] = [:]
    private var lastAlert: [String: TimeInterval] = [:]
    private var top: [ProcessGroup] = []
    private static let ringsKey = "menuBarRings"
    private var shown: [SystemRing] = shownRings(stored: UserDefaults.standard.stringArray(forKey: ringsKey))
    private let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["CLAUDE_SYSTEM_FILE"] ?? "~/.claude/system.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    init(lang: Lang) {
        self.lang = lang
        super.init()
    }

    func start() {
        seedStatusItemPosition("claude-limits.system")
        statusItem.autosaveName = "claude-limits.system"  // our own name, see AppDelegate
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = SystemStrings.of(lang).tooltip
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        cpuTicks = SystemProbe.cpuTicks()
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
        if let ticks = SystemProbe.cpuTicks() {
            cpu = cpuPercent(previous: cpuTicks, current: ticks) ?? cpu
            cpuTicks = ticks
        }
        gpu = SystemProbe.gpu()
        queue = SystemProbe.queue()
        top = groupProcesses(SystemProbe.processes(), limit: 7)
        let json = systemJSON(memory: memory, disk: disk, top: top, cpu: cpu, gpu: gpu, queue: queue,
                              updatedAt: Date().timeIntervalSince1970)
        try? Data((json + "\n").utf8).write(to: fileURL, options: .atomic)
        drawIcon()
        let text = SystemStrings.of(lang)
        if let memory {
            alertIfNeeded("memory", memoryLevel(memory), title: text.memoryAlert, body: memoryLine(memory, lang: lang))
        }
        if let disk {
            alertIfNeeded("disk", diskLevel(disk), title: text.diskAlert, body: diskLine(disk, lang: lang))
        }
    }

    private func ringState(_ ring: SystemRing) -> RingState {
        switch ring {
        case .cpu: return loadRing(cpu)
        case .gpu: return loadRing(gpu.map { Double($0.utilization) })
        case .memory: return memoryRing(memory)
        case .disk: return diskRing(disk)
        }
    }

    private func drawIcon() {
        statusItem.button?.image = RingIcon.systemImage(shown.map { ($0, ringState($0)) })
    }

    @objc private func toggleRing(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let ring = SystemRing(rawValue: name) else { return }
        shown = toggled(ring, in: shown)
        UserDefaults.standard.set(shown.map(\.rawValue), forKey: Self.ringsKey)
        drawIcon()
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

        menu.addItem(stateItem(cpuLine(cpu, lang: lang), state: loadRing(cpu)))
        menu.addItem(stateItem(gpuLine(gpu, lang: lang), state: loadRing(gpu.map { Double($0.utilization) })))
        if let line = queueLine(queue, lang: lang) { menu.addItem(noteItem(line, indented: true)) }
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
        menu.addItem(noteItem(text.showInMenuBar, indented: false))
        for ring in SystemRing.allCases {
            let item = NSMenuItem(title: ringName(ring, lang: lang), action: #selector(toggleRing(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ring.rawValue
            item.state = shown.contains(ring) ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
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
