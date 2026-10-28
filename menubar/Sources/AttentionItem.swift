import AppKit
import UserNotifications

// Third menu bar item: a bell with the number of Claude sessions waiting on the person,
// shown only while one waits. Its menu lists them; a row opens its session in the Claude
// app. A session waiting five minutes brings one notification, which opens it too. Every
// 2 s the list also goes to ~/.claude/attention.json for the desktop mod.

enum AttentionFiles {
    static let claudeBundle = "com.anthropic.claudefordesktop"

    private static func url(_ variable: String, _ fallback: String) -> URL {
        let path = ProcessInfo.processInfo.environment[variable] ?? fallback
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static let stateDir = url("CLAUDE_ATTENTION_DIR", "~/.claude/attention")
    static let listFile = url("CLAUDE_ATTENTION_FILE", "~/.claude/attention.json")
    static let appSessionsDir = url("CLAUDE_APP_SESSIONS_DIR",
                                    "~/Library/Application Support/Claude/claude-code-sessions")

    /// The mods' state files; an ended session's file is removed, as the mod cannot.
    static func readStates() -> [SessionStateFile] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let state = parseStateFile(data) else { return nil }
            if state.state == .ended {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return state
        }
    }

    /// The Claude app's session files, parsed again only when one changed on disk.
    final class AppSessionCache {
        private var entries: [String: (modified: Date, session: AppSession?)] = [:]

        func sessions() -> [AppSession] {
            var seen: [String: (modified: Date, session: AppSession?)] = [:]
            let manager = FileManager.default
            let accounts = (try? manager.contentsOfDirectory(at: appSessionsDir, includingPropertiesForKeys: nil)) ?? []
            for account in accounts {
                for org in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                    let files = (try? manager.contentsOfDirectory(
                        at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                    for file in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        if let cached = entries[file.path], cached.modified == modified {
                            seen[file.path] = cached
                        } else {
                            seen[file.path] = (modified, (try? Data(contentsOf: file)).flatMap(parseAppSession))
                        }
                    }
                }
            }
            entries = seen
            return seen.values.compactMap(\.session)
        }
    }

    static func claudeIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundle
    }

    static func current(cache: AppSessionCache = AppSessionCache()) -> [WaitingSession] {
        waitingSessions(states: readStates(), apps: cache.sessions(), claudeIsFrontmost: claudeIsFrontmost())
    }

    static func open(_ link: String) {
        guard link.hasPrefix("claude://claude.ai/epitaxy/local_"), let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

final class AttentionItem: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lang: Lang
    private let cache = AttentionFiles.AppSessionCache()
    private let startedAt = Date().timeIntervalSince1970
    private var timer: Timer?
    private var sessions: [WaitingSession] = []
    private var reminded: Set<String> = []

    init(lang: Lang) {
        self.lang = lang
        super.init()
    }

    func start() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = false
        statusItem.button?.toolTip = AttentionStrings.of(lang).tooltip
        UNUserNotificationCenter.current().delegate = self
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }

    @objc private func tick() {
        refresh()
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970
        sessions = waitingSessions(states: AttentionFiles.readStates(), apps: cache.sessions(),
                                   claudeIsFrontmost: AttentionFiles.claudeIsFrontmost())
        let json = attentionJSON(sessions, updatedAt: now)
        try? FileManager.default.createDirectory(at: AttentionFiles.listFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data((json + "\n").utf8).write(to: AttentionFiles.listFile, options: .atomic)
        draw(bell(sessions))
        remind(now: now)
    }

    private func draw(_ bell: Bell?) {
        guard let bell, let button = statusItem.button else {
            statusItem.isVisible = false
            return
        }
        button.image = RingIcon.bellImage(bell)
        statusItem.isVisible = true
    }

    private func remind(now: TimeInterval) {
        reminded.formIntersection(Set(sessions.map(\.episode)))
        for session in remindersDue(sessions, reminded: reminded, startedAt: startedAt, now: now) {
            reminded.insert(session.episode)
            let content = UNMutableNotificationContent()
            content.title = AttentionStrings.of(lang).reminderTitle
            content.body = attentionLine(session, now: now, lang: lang)
            content.sound = .default
            content.userInfo = ["link": session.link]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "attention-\(session.episode)", content: content, trigger: nil))
        }
    }

    // Shown even while the menu holds the app active, as without a delegate.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // A press on a reminder opens its session; other notifications of the app carry no link.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["link"] as? String {
            AttentionFiles.open(link)
        }
        completionHandler()
    }

    private func rebuildMenu() {
        let now = Date().timeIntervalSince1970
        menu.removeAllItems()
        for session in sessions {
            let font = NSFont.menuFont(ofSize: 0)
            let line = attentionLine(session, now: now, lang: lang)
            let text = NSMutableAttributedString(string: "● ", attributes: [
                .font: font, .foregroundColor: session.state.isBlocking ? NSColor.systemOrange : NSColor.systemGreen,
            ])
            text.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            let item = NSMenuItem(title: line, action: #selector(openSession(_:)), keyEquivalent: "")
            item.attributedTitle = text
            item.representedObject = session.link
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String { AttentionFiles.open(link) }
    }
}
