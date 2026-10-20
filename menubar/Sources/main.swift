import AppKit

let app = NSApplication.shared

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--preview" {
    exit(Preview.render(to: arguments[2]) ? 0 : 1)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
