import Foundation
import UserNotifications

/// A coding job an agent does on its own in the background, for the user to review afterwards.
struct AgentTask: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, running, review, failed, cancelled, applied, discarded }
    /// Where the agent works: a separate git worktree of the last commit, or the project folder itself.
    enum Workspace: String, Codable { case copy, folder }

    let id: UUID
    let prompt: String
    let agent: String
    let project: String
    let workspace: Workspace
    var state = State.queued
    var created = Date()
    var started: Date?
    var finished: Date?
    var directory: String?
    /// The commit, or snapshot of the working tree, the task started from; its changes are measured against it.
    var base: String?
    var branch: String?
    var untrackedBefore: [String] = []
    var changedFiles: [String] = []
    var insertions = 0
    var deletions = 0
    var message: String?

    var title: String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 90 ? String(line.prefix(88)) + "…" : line
    }
    var short: String { String(id.uuidString.prefix(8)).lowercased() }
    var settled: Bool { [.failed, .cancelled, .applied, .discarded].contains(state) || (state == .review && changedFiles.isEmpty) }
}

/// Git, as the task runner uses it. Every call is synchronous; callers run it off the main thread.
enum Git {
    @discardableResult
    static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 120) throws -> String {
        let result = try Kapitsa.runSync("/usr/bin/git", arguments, env: environment, directory: URL(fileURLWithPath: directory), timeout: timeout)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.code == 0 else {
            throw Kapitsa.Failure(errorDescription: output.split(separator: "\n").last.map(String.init) ?? "git \(arguments.first ?? "") failed")
        }
        return output
    }

    /// Exit status alone, for commands such as `diff --quiet` that answer with it.
    static func status(_ arguments: [String], in directory: String) -> Int32 {
        (try? Kapitsa.runSync("/usr/bin/git", arguments, env: environment, directory: URL(fileURLWithPath: directory), timeout: 120))?.code ?? -1
    }

    static func isRepository(_ directory: String) -> Bool { (try? run(["rev-parse", "--is-inside-work-tree"], in: directory)) == "true" }

    static func lines(_ output: String) -> [String] { output.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    /// Never prompt, never page, and identify the task commits Nearloop makes on its own branches.
    private static var environment: [String: String] {
        var env = Kapitsa.environment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        return env
    }
}

@MainActor
final class TaskRunner: ObservableObject {
    static let shared = TaskRunner()
    @Published private(set) var tasks: [AgentTask] = []
    /// The running task's latest output, cleaned of terminal escapes.
    @Published private(set) var output: [String] = []
    private var process: Process?
    private var cancelled = false
    /// True from picking a task until it has finished, so only one runs at a time.
    private var busy = false

    /// Agents whose non-interactive mode works against a local model, and how to start one on a task.
    /// They act without asking for approval, which is why tasks default to a separate copy of the project.
    /// Claude Code's `-p` mode rejects local model names, so it isn't offered yet.
    static let agents = ["opencode", "pi", "codex"]

    static func arguments(_ agent: String, _ prompt: String) -> [String] {
        switch agent {
        case "opencode": return ["run", "--auto", prompt]
        case "pi": return ["-p", "--no-session", "--thinking", "off", prompt]
        case "codex": return ["exec", "--full-auto", prompt]
        default: return [prompt]
        }
    }

    private static var folder: URL { AppPaths.folder("tasks") }
    private static var listURL: URL { folder.appendingPathComponent("tasks.json") }
    static func logURL(_ task: AgentTask) -> URL { folder.appendingPathComponent("\(task.id.uuidString).log") }

    var active: Int { tasks.filter { $0.state == .queued || $0.state == .running }.count }

    private init() {
        if let data = try? Data(contentsOf: Self.listURL), let saved = try? JSONDecoder().decode([AgentTask].self, from: data) {
            tasks = saved.map { task in
                var task = task
                // A task can't survive the app quitting: its agent was stopped with it.
                if task.state == .running { task.state = .failed; task.message = "Interrupted: Nearloop quit while it ran." }
                return task
            }
        }
        Task { await runNext() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) { try? data.write(to: Self.listURL, options: .atomic) }
    }

    private func update(_ id: UUID, _ change: (inout AgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        save()
    }

    // MARK: Queue

    func add(prompt: String, agent: String, project: String, workspace: AgentTask.Workspace) throws {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard Git.isRepository(project) else {
            throw Kapitsa.Failure(errorDescription: "\(URL(fileURLWithPath: project).lastPathComponent) isn’t a git repository. Tasks use git so you can review and undo what the agent changed; run “git init” and commit once first.")
        }
        tasks.append(AgentTask(id: UUID(), prompt: prompt, agent: agent, project: project, workspace: workspace))
        save()
        Prefs.rememberProject(project)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await runNext() }
    }

    func cancel(_ id: UUID) {
        if let task = tasks.first(where: { $0.id == id }), task.state == .queued {
            update(id) { $0.state = .cancelled }
        } else if tasks.first(where: { $0.id == id })?.state == .running, let process, process.isRunning {
            cancelled = true
            process.interrupt()
        }
    }

    func retry(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        tasks.append(AgentTask(id: UUID(), prompt: task.prompt, agent: task.agent, project: task.project, workspace: task.workspace))
        save()
        Task { await runNext() }
    }

    /// Removes a finished task from the list; its workspace must already be kept or discarded.
    func remove(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.state != .running else { return }
        if task.state == .review || task.state == .failed { discard(id) }
        tasks.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.logURL(task))
        save()
    }

    /// Stops the running agent when the app quits.
    func stopAll() {
        if let process, process.isRunning { process.terminate() }
    }

    private func runNext() async {
        guard !busy, let next = tasks.first(where: { $0.state == .queued }) else { return }
        busy = true
        let id = next.id
        update(id) { $0.state = .running; $0.started = Date(); $0.message = nil }
        output = []
        cancelled = false
        do {
            guard AppStore.shared.agents[next.agent] != nil else {
                throw Kapitsa.Failure(errorDescription: "\(Agents.displayName(next.agent)) is not installed.")
            }
            let prepared = try await Task.detached { try Self.prepare(next) }.value
            update(id) { $0 = prepared }
            try await AppStore.shared.ensureServer(for: next.agent)
            try start(prepared)
        } catch {
            finish(id, failure: error.localizedDescription)
        }
    }

    /// Sets up where the agent works and records the starting point.
    nonisolated static func prepare(_ task: AgentTask) throws -> AgentTask {
        var task = task
        guard let head = try? Git.run(["rev-parse", "HEAD"], in: task.project) else {
            throw Kapitsa.Failure(errorDescription: "The repository has no commits yet. Commit once so the task has a starting point.")
        }
        switch task.workspace {
        case .copy:
            let directory = AppPaths.folder("worktrees").appendingPathComponent(task.short).path
            let branch = "nearloop/task-\(task.short)"
            try Git.run(["worktree", "add", "-b", branch, directory, head], in: task.project)
            task.directory = directory
            task.branch = branch
            task.base = head
        case .folder:
            // Uncommitted changes count as the starting point too, so only the agent's changes are shown.
            let snapshot = (try? Git.run(["stash", "create"], in: task.project)) ?? ""
            let base = snapshot.isEmpty ? head : snapshot
            try Git.run(["update-ref", "refs/nearloop/\(task.short)", base], in: task.project)
            task.directory = task.project
            task.base = base
            task.untrackedBefore = Git.lines((try? Git.run(["ls-files", "--others", "--exclude-standard"], in: task.project)) ?? "")
        }
        return task
    }

    private func start(_ task: AgentTask) throws {
        guard let binary = Kapitsa.binary, let directory = task.directory else {
            throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.")
        }
        let server = ServerController.shared
        var arguments = [task.agent, "--port", String(server.port)]
        if !server.apiKey.isEmpty { arguments += ["--api-key", server.apiKey] }
        arguments += ["--"] + Self.arguments(task.agent, task.prompt)

        let log = Self.logURL(task)
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(task.agent) · \(task.prompt)\n\n".utf8))
        let writer = try FileHandle(forWritingTo: log)
        writer.seekToEndOfFile()

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = Kapitsa.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            writer.write(data)
            let lines = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n").map { Kapitsa.clean(String($0)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            Task { @MainActor in
                guard let self else { return }
                self.output.append(contentsOf: lines)
                if self.output.count > 400 { self.output.removeFirst(self.output.count - 400) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? writer.close()
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                if self.cancelled {
                    self.finish(task.id, cancelled: true)
                } else if finished.terminationStatus != 0 {
                    self.finish(task.id, failure: self.output.last ?? "\(Agents.displayName(task.agent)) exited with code \(finished.terminationStatus).")
                } else {
                    self.finish(task.id)
                }
            }
        }
        server.measurePrompt(of: task.agent)
        try process.run()
        self.process = process
    }

    /// Records what changed, tells the user, and starts the next task.
    private func finish(_ id: UUID, failure: String? = nil, cancelled: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let lastWords = output.suffix(3).joined(separator: " ")
        Task {
            let measured = task.directory == nil ? task : await Task.detached { Self.measure(task) }.value
            update(id) {
                $0 = measured
                $0.finished = Date()
                if cancelled { $0.state = .cancelled; $0.message = "Cancelled." }
                else if let failure { $0.state = .failed; $0.message = failure }
                else { $0.state = .review; $0.message = lastWords.isEmpty ? nil : String(lastWords.suffix(300)) }
            }
            if let done = tasks.first(where: { $0.id == id }) { notify(done) }
            busy = false
            await runNext()
        }
    }

    /// Commits a worktree's changes to the task branch, and counts what changed against the starting point.
    nonisolated static func measure(_ task: AgentTask) -> AgentTask {
        var task = task
        guard let directory = task.directory, let base = task.base else { return task }
        var numstat = ""
        switch task.workspace {
        case .copy:
            _ = try? Git.run(["add", "-A"], in: directory)
            if Git.status(["diff", "--cached", "--quiet"], in: directory) == 1 {
                _ = try? Git.run(["-c", "user.name=Nearloop", "-c", "user.email=nearloop@localhost", "commit", "--no-verify", "-q",
                                  "-m", "Nearloop task: \(task.title)"], in: directory)
            }
            numstat = (try? Git.run(["diff", "--numstat", base, "HEAD"], in: directory)) ?? ""
            task.changedFiles = []
        case .folder:
            numstat = (try? Git.run(["diff", "--numstat", base], in: directory)) ?? ""
            let untracked = Git.lines((try? Git.run(["ls-files", "--others", "--exclude-standard"], in: directory)) ?? "")
            task.changedFiles = untracked.filter { !task.untrackedBefore.contains($0) }
        }
        task.insertions = 0
        task.deletions = 0
        for line in Git.lines(numstat) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            task.insertions += Int(parts[0]) ?? 0
            task.deletions += Int(parts[1]) ?? 0
            task.changedFiles.append(parts[2])
        }
        return task
    }

    private func notify(_ task: AgentTask) {
        let content = UNMutableNotificationContent()
        switch task.state {
        case .review:
            content.title = task.changedFiles.isEmpty ? "Task finished, no changes" : "Task ready to review"
            content.body = "\(task.title) · \(task.changedFiles.count) files changed"
        case .failed:
            content.title = "Task failed"
            content.body = task.title
        default: return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Review

    /// The task's changes as a unified diff, plus the files it created.
    func diff(_ task: AgentTask) async -> String {
        await Task.detached {
            guard let directory = task.directory, let base = task.base else { return "" }
            var text: String
            switch task.workspace {
            case .copy: text = (try? Git.run(["diff", base, "HEAD"], in: directory)) ?? ""
            case .folder:
                text = (try? Git.run(["diff", base], in: directory)) ?? ""
                let created = task.changedFiles.filter { task.untrackedBefore.contains($0) == false && !text.contains(" b/\($0)") }
                if !created.isEmpty { text += "\n\nNew files:\n" + created.map { "  + " + $0 }.joined(separator: "\n") }
            }
            return text.count > 400_000 ? String(text.prefix(400_000)) + "\n… (diff truncated)" : text
        }.value
    }

    /// Brings a task's changes into the project. A worktree's commit is applied without committing, so the
    /// changes appear in the project as uncommitted (staged) edits; work in the folder itself is just kept.
    func apply(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.state == .review else { return }
        Task {
            do {
                try await Task.detached { try Self.applyChanges(task) }.value
                update(id) { $0.state = .applied; $0.message = task.workspace == .copy ? "Applied to the project as uncommitted changes." : "Kept." }
            } catch {
                update(id) { $0.message = "Couldn’t apply cleanly: \(error.localizedDescription). The changes are on the branch \(task.branch ?? "")." }
            }
        }
    }

    /// Throws the task's changes away: removes its worktree and branch, or restores the files it changed
    /// in the folder and deletes the ones it created.
    func discard(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.state == .review || task.state == .failed else { return }
        Task {
            await Task.detached { Self.discardChanges(task) }.value
            update(id) { $0.state = .discarded; $0.message = "Discarded." }
        }
    }

    nonisolated static func applyChanges(_ task: AgentTask) throws {
        if task.workspace == .copy, let branch = task.branch, !task.changedFiles.isEmpty {
            try Git.run(["cherry-pick", "--no-commit", branch], in: task.project)
        }
        cleanUp(task)
    }

    nonisolated static func discardChanges(_ task: AgentTask) {
        if task.workspace == .folder, let base = task.base {
            let tracked = Git.lines((try? Git.run(["diff", "--name-only", base], in: task.project)) ?? "")
            if !tracked.isEmpty { _ = try? Git.run(["checkout", base, "--"] + tracked, in: task.project) }
            for file in task.changedFiles where !tracked.contains(file) && !task.untrackedBefore.contains(file) {
                try? FileManager.default.removeItem(atPath: (task.project as NSString).appendingPathComponent(file))
            }
        }
        cleanUp(task)
    }

    nonisolated private static func cleanUp(_ task: AgentTask) {
        switch task.workspace {
        case .copy:
            if let directory = task.directory { _ = try? Git.run(["worktree", "remove", "--force", directory], in: task.project) }
            if let branch = task.branch { _ = try? Git.run(["branch", "-D", branch], in: task.project) }
        case .folder:
            _ = try? Git.run(["update-ref", "-d", "refs/nearloop/\(task.short)"], in: task.project)
        }
    }
}
