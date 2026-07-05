import AppKit
import Foundation

enum TerminalService {
    static func openTerminal(at url: URL) {
        let script = "tell application \"Terminal\" to do script \"cd " + shellQuoted(url.path) + "\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum QuickLookBridge {
    static func preview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + urls.map(\.path)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
