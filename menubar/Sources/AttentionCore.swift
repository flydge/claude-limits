import Foundation

// Pure logic for the third menu bar item: Claude sessions waiting on the person. Each
// session's mod writes ~/.claude/attention/<cli id>.json; the Claude app keeps a file per
// session with its title, archive flag and when it was last opened. Gathered here into
// ~/.claude/attention.json for the desktop mod. No AppKit or system calls here.

enum AttentionState: String, Equatable {
    case working, permission, question, decision, done, ended

    /// Orange, at the head of the list: the person's answer or decision is wanted.
    var isBlocking: Bool { self == .permission || self == .question || self == .decision }
}

/// `~/.claude/attention/<cli id>.json`, as the mod writes it.
struct SessionStateFile: Equatable {
    let cliId: String
    let state: AttentionState
    let since: TimeInterval
}

/// A session file of the Claude app (`claude-code-sessions/*/*/local_*.json`): only the
/// fields read here, `lastFocusedAt` in seconds.
struct AppSession: Equatable {
    let id: String
    let cliId: String
    let title: String
    let isArchived: Bool
    let lastFocusedAt: TimeInterval
}

struct WaitingSession: Equatable {
    let id: String
    let cliId: String
    let title: String
    let state: AttentionState
    let since: TimeInterval

    /// Opens the session in the Claude app.
    var link: String { "claude://claude.ai/epitaxy/\(id)" }
    /// One waiting spell: a new state or a new start is a new one, reminded anew.
    var episode: String { "\(cliId)|\(state.rawValue)|\(Int(since))" }
}

/// The user's choice: one reminder once a session has waited five minutes.
let reminderAfter: TimeInterval = 300

func parseStateFile(_ data: Data) -> SessionStateFile? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cliId = object["session_id"] as? String, !cliId.isEmpty,
          let state = (object["state"] as? String).flatMap(AttentionState.init(rawValue:)),
          let since = object["since"] as? Double else { return nil }
    return SessionStateFile(cliId: cliId, state: state, since: since)
}

func parseAppSession(_ data: Data) -> AppSession? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["sessionId"] as? String, id.hasPrefix("local_"),
          let cliId = object["cliSessionId"] as? String, !cliId.isEmpty else { return nil }
    return AppSession(id: id, cliId: cliId, title: object["title"] as? String ?? "",
                      isArchived: object["isArchived"] as? Bool ?? false,
                      lastFocusedAt: (object["lastFocusedAt"] as? Double ?? 0) / 1000)
}

/// The sessions to show. A session shows while it waits for permission, an answer, a decision
/// or a look at a finished turn, and only as a live session of the Claude app: one the app does not
/// know (a terminal session) or keeps archived is left out. A finished turn counts as seen
/// once the session was opened after it, or while it is the one on screen in a frontmost
/// Claude app. Blocking sessions first, then finished ones; the longest waiting first.
func waitingSessions(states: [SessionStateFile], apps: [AppSession], claudeIsFrontmost: Bool) -> [WaitingSession] {
    var byCli: [String: AppSession] = [:]
    for app in apps where byCli[app.cliId].map({ app.lastFocusedAt > $0.lastFocusedAt }) ?? true {
        byCli[app.cliId] = app
    }
    let onScreen = apps.max { $0.lastFocusedAt < $1.lastFocusedAt }?.id
    return states.compactMap { file -> WaitingSession? in
        guard file.state.isBlocking || file.state == .done,
              let app = byCli[file.cliId], !app.isArchived else { return nil }
        if file.state == .done {
            if app.lastFocusedAt > file.since { return nil }
            if claudeIsFrontmost && app.id == onScreen { return nil }
        }
        return WaitingSession(id: app.id, cliId: file.cliId, title: app.title, state: file.state, since: file.since)
    }
    .sorted {
        if $0.state.isBlocking != $1.state.isBlocking { return $0.state.isBlocking }
        if $0.since != $1.since { return $0.since < $1.since }
        return $0.title < $1.title
    }
}

/// What the bell shows: nothing when no session waits; orange while one is blocked, green
/// when they are only done.
struct Bell: Equatable {
    let count: Int
    let isBlocking: Bool
}

func bell(_ sessions: [WaitingSession]) -> Bell? {
    sessions.isEmpty ? nil : Bell(count: sessions.count, isBlocking: sessions.contains { $0.state.isBlocking })
}

/// Sessions to remind of now: each waiting spell once, when it passes `reminderAfter`.
/// A spell that passed it before the app started is not reminded, so a login brings no burst.
func remindersDue(_ sessions: [WaitingSession], reminded: Set<String>, startedAt: TimeInterval,
                  now: TimeInterval) -> [WaitingSession] {
    sessions.filter {
        now - $0.since >= reminderAfter && $0.since + reminderAfter >= startedAt && !reminded.contains($0.episode)
    }
}

struct AttentionStrings {
    let permission, question, decision, done, minutes, untitled, tooltip, reminderTitle: String

    static func of(_ lang: Lang) -> AttentionStrings {
        switch lang {
        case .ru:
            return AttentionStrings(permission: "нужно разрешение", question: "вопрос", decision: "ждёт решения",
                                    done: "готово",
                                    minutes: "мин", untitled: "Сессия без названия",
                                    tooltip: "Сессии Claude, которые ждут ответа",
                                    reminderTitle: "Claude ждёт ответа")
        case .en:
            return AttentionStrings(permission: "needs permission", question: "has a question",
                                    decision: "needs your decision", done: "done",
                                    minutes: "min", untitled: "Untitled session",
                                    tooltip: "Claude sessions waiting for you",
                                    reminderTitle: "Claude is waiting for you")
        }
    }

    func label(_ state: AttentionState) -> String {
        switch state {
        case .permission: return permission
        case .question: return question
        case .decision: return decision
        default: return done
        }
    }
}

/// `Пепельная дорога · нужно разрешение · 3 мин`
func attentionLine(_ session: WaitingSession, now: TimeInterval, lang: Lang) -> String {
    let text = AttentionStrings.of(lang)
    let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let minutes = max(0, Int((now - session.since) / 60))
    return "\(title.isEmpty ? text.untitled : title) · \(text.label(session.state)) · \(minutes) \(text.minutes)"
}

/// `~/.claude/attention.json` and `ClaudeLimits --attention-json`, read by the desktop mod.
func attentionJSON(_ sessions: [WaitingSession], updatedAt: TimeInterval? = nil) -> String {
    var object: [String: Any] = [:]
    if let updatedAt { object["updated_at"] = Int(updatedAt) }
    object["sessions"] = sessions.map {
        ["id": $0.id, "cli_id": $0.cliId, "title": $0.title, "state": $0.state.rawValue,
         "since": Int($0.since), "link": $0.link] as [String: Any]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
