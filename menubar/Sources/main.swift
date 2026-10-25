import AppKit

let app = NSApplication.shared

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--preview" {
    exit(Preview.render(to: arguments[2]) ? 0 : 1)
}
// Memory, disk and top apps as JSON for the desktop mod:  ClaudeLimits --system-json
if arguments.count == 2, arguments[1] == "--system-json" {
    print(systemJSON(memory: SystemProbe.memory(), disk: SystemProbe.disk(),
                     top: groupProcesses(SystemProbe.processes(), limit: 7)))
    exit(0)
}
// Prints what the system item's menu would show:  ClaudeLimits --system
if arguments.count == 2, arguments[1] == "--system" {
    let lang = Lang.resolve(override: ProcessInfo.processInfo.environment["CLAUDE_LIMITS_LANG"],
                            preferred: Locale.preferredLanguages)
    let memory = SystemProbe.memory(), disk = SystemProbe.disk()
    print(memoryLine(memory, lang: lang), memoryRing(memory))
    if let memory { print("  " + memoryDetailLine(memory, lang: lang)) }
    print(diskLine(disk, lang: lang), diskRing(disk))
    for group in groupProcesses(SystemProbe.processes(), limit: 7) { print("  " + processLine(group, lang: lang)) }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
