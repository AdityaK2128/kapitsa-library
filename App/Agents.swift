import AppKit
import Foundation

struct AgentInfo: Identifiable, Hashable {
    let id: String          // the command, and Kapitsa's agent name
    let name: String
    let maker: String
    let summary: String
    let symbol: String
    let install: String
    let homepage: URL
}

enum Agents {
    static let catalog: [AgentInfo] = [
        AgentInfo(id: "claude", name: "Claude Code", maker: "Anthropic", summary: "Anthropic’s agentic coding tool, connected through the Messages API.",
                  symbol: "sparkles", install: "curl -fsSL https://claude.ai/install.sh | bash",
                  homepage: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!),
        AgentInfo(id: "opencode", name: "OpenCode", maker: "SST", summary: "Open-source coding agent with a full-screen terminal interface.",
                  symbol: "chevron.left.forwardslash.chevron.right", install: "curl -fsSL https://opencode.ai/install | bash",
                  homepage: URL(string: "https://opencode.ai")!),
        AgentInfo(id: "codex", name: "Codex CLI", maker: "OpenAI", summary: "OpenAI’s coding agent, connected through the Responses API.",
                  symbol: "terminal", install: "npm install -g @openai/codex",
                  homepage: URL(string: "https://github.com/openai/codex")!),
        AgentInfo(id: "pi", name: "Pi", maker: "Mario Zechner", summary: "Minimal, extensible coding agent. Launches with thinking disabled for faster responses.",
                  symbol: "pi", install: "curl -fsSL https://pi.dev/install.sh | sh",
                  homepage: URL(string: "https://pi.dev")!),
    ]
    static var all: [String] { catalog.map(\.id) }

    static func displayName(_ key: String) -> String { catalog.first { $0.id == key }?.name ?? key }

    /// Agents on the user's login PATH (Kapitsa's `kapitsa <agent>` starts them from there).
    static func installed() -> [String: String] {
        let directories = Kapitsa.loginPath.split(separator: ":").map(String.init)
        var found: [String: String] = [:]
        for name in all {
            if let dir = directories.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }) { found[name] = dir + "/" + name }
        }
        return found
    }

    static func version(_ path: String) -> String {
        let output = (try? Kapitsa.runSync(path, ["--version"], env: Kapitsa.environment(), timeout: 5))?.output ?? ""
        return output.split(separator: "\n").first.map { String($0.prefix(40)).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static var ghostty: URL? {
        [URL(fileURLWithPath: "/Applications/Ghostty.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/ghostty").path) }
    }

    /// Writes a small launcher script and opens it in the user's terminal of choice.
    static func launch(_ name: String, project: URL, port: Int, apiKey: String) throws {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Kapitsa Library.") }
        var command = [binary.path, name, "--port", String(port)]
        if !apiKey.isEmpty { command += ["--api-key", apiKey] }
        if name == "pi" { command += ["--", "--thinking", "off"] }
        let env = Kapitsa.environment()
        var script = "#!/bin/zsh\nset -euo pipefail\n"
        for key in ["PATH", "KAPITSA_NO_AUTO_UPDATE", "KAPITSA_HOME", "HF_HOME", "HF_HUB_CACHE", "XDG_CACHE_HOME"] {
            if let value = env[key] { script += "export \(key)=\(quote(value))\n" }
        }
        script += "cd \(quote(project.path))\n"
        script += "clear\nprint \(quote("\(displayName(name)) on Kapitsa · \(project.lastPathComponent)"))\n"
        script += "exec " + command.map(quote).joined(separator: " ") + "\n"

        let folder = AppPaths.folder("launchers")
        cleanOldLaunchers(folder)
        let file = folder.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970)).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        Prefs.rememberProject(project.path)

        if Prefs.terminal == "ghostty", let ghostty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", ghostty.path, "--args", "--window-save-state=never",
                                 "--quit-after-last-window-closed=true", "--wait-after-command=true",
                                 "--title=\(displayName(name)) · \(project.lastPathComponent)",
                                 "--working-directory=\(project.path)", "-e", "/bin/zsh", file.path]
            try process.run()
        } else {
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cleanOldLaunchers(_ folder: URL) {
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
