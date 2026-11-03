import SwiftUI

struct TasksView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var runner = TaskRunner.shared
    @State private var prompt = ""
    @State private var project = Prefs.recentProjects.first ?? ""
    @State private var agent = ""
    @State private var workspace = AgentTask.Workspace.copy
    @State private var diffTask: AgentTask?

    private var available: [AgentInfo] { Agents.catalog.filter { TaskRunner.agents.contains($0.id) && store.agents[$0.id] != nil } }

    var body: some View {
        PageScaffold(title: "Tasks", subtitle: "Give an agent a job and let it work in the background on the local model. Review what it changed, then keep or discard it.") {
            newTaskCard
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Queue", detail: runner.tasks.isEmpty ? nil : queueDetail)
                if runner.tasks.isEmpty {
                    ContentUnavailableView("No Tasks", systemImage: "checklist",
                                           description: Text("Tasks run one at a time, so you can queue several and come back later."))
                        .frame(maxWidth: .infinity).padding(.vertical, 30).card()
                } else {
                    ForEach(runner.tasks.reversed()) { task in
                        TaskRow(task: task, runner: runner) { diffTask = task }
                    }
                }
            }
        }
        .sheet(item: $diffTask) { DiffSheet(task: $0, runner: runner) }
        .onAppear { if agent.isEmpty || !available.contains(where: { $0.id == agent }) { agent = available.first?.id ?? "" } }
    }

    private var queueDetail: String {
        let waiting = runner.tasks.filter { $0.state == .queued }.count
        let review = runner.tasks.filter { $0.state == .review && !$0.changedFiles.isEmpty }.count
        return [runner.tasks.contains { $0.state == .running } ? "1 running" : nil, waiting > 0 ? "\(waiting) waiting" : nil,
                review > 0 ? "\(review) to review" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var newTaskCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Task").font(.headline)
            if available.isEmpty {
                Text("Tasks need OpenCode, Pi or Codex CLI, which can work without a terminal. Install one from the Agents page. (Claude Code can’t run unattended on local models yet.)")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    Text("Project").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Picker("Project", selection: $project) {
                        if project.isEmpty { Text("Choose a project").tag("") }
                        ForEach(projects, id: \.self) { Text(Self.display($0)).tag($0) }
                    }.labelsHidden().frame(maxWidth: 420, alignment: .leading)
                    Button("Choose…") { if let url = store.chooseProject() { project = url.path } }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("Agent").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Picker("Agent", selection: $agent) {
                        ForEach(available) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).padding(6)
                        .frame(minHeight: 90, maxHeight: 180)
                    if prompt.isEmpty {
                        Text("What should the agent do? For example: “Add unit tests for the date parser and make them pass.”")
                            .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                HStack(alignment: .top, spacing: 10) {
                    Text("Works in").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Works in", selection: $workspace) {
                            Text("A separate copy").tag(AgentTask.Workspace.copy)
                            Text("The project folder").tag(AgentTask.Workspace.folder)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(workspace == .copy
                             ? "A git worktree of your last commit; your files stay untouched until you apply the result. Uncommitted changes and ignored folders (such as node_modules) aren’t in the copy."
                             : "Works on your files directly, with their dependencies. Discard restores the files it changed and deletes the ones it created; avoid editing the project while it runs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    Label("Agents run tasks without asking for approval: they can edit files and run commands on your Mac. Use projects you trust.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button { add() } label: { Label("Add Task", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.isEmpty || agent.isEmpty)
                }
            }
        }.card()
    }

    private var projects: [String] {
        var list = Prefs.recentProjects
        if !project.isEmpty && !list.contains(project) { list.insert(project, at: 0) }
        return list
    }

    static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func add() {
        do {
            try runner.add(prompt: prompt, agent: agent, project: project, workspace: workspace)
            prompt = ""
        } catch { store.errorMessage = error.localizedDescription }
    }
}

private struct TaskRow: View {
    let task: AgentTask
    @ObservedObject var runner: TaskRunner
    let showDiff: () -> Void
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon.font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.body.weight(.medium)).lineLimit(2)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let message = task.message, task.state != .running {
                        Text(message).font(.caption).foregroundStyle(task.state == .failed ? .orange : .secondary)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                actions.controlSize(.small).fixedSize()
            }
            if task.state == .running {
                Text(runner.output.suffix(6).joined(separator: "\n").ifEmpty("Starting \(Agents.displayName(task.agent))…"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            } else if showLog {
                ScrollView {
                    Text(log).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(maxHeight: 220).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }.card(padding: 16)
    }

    private var details: String {
        var parts = [TasksView.display(task.project), Agents.displayName(task.agent), task.workspace == .copy ? "separate copy" : "project folder"]
        if let started = task.started {
            let end = task.finished ?? Date()
            parts.append(Duration.seconds(end.timeIntervalSince(started)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
        }
        if task.state == .review || task.state == .applied {
            parts.append(task.changedFiles.isEmpty ? "no changes" : "\(task.changedFiles.count) files · +\(task.insertions) −\(task.deletions)")
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var statusIcon: some View {
        switch task.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting")
        case .running: ProgressView().controlSize(.small)
        case .review: Image(systemName: task.changedFiles.isEmpty ? "checkmark.circle" : "eye.circle.fill")
            .foregroundStyle(task.changedFiles.isEmpty ? Color.secondary : Color.accentColor).help(task.changedFiles.isEmpty ? "Finished" : "Ready to review")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Failed")
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary).help("Cancelled")
        case .applied: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Kept")
        case .discarded: Image(systemName: "trash.circle").foregroundStyle(.secondary).help("Discarded")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch task.state {
            case .queued, .running:
                Button("Cancel", role: .destructive) { runner.cancel(task.id) }
            case .review where !task.changedFiles.isEmpty:
                Button("Show Changes") { showDiff() }
                Button("Discard", role: .destructive) { runner.discard(task.id) }
                Button(task.workspace == .copy ? "Apply" : "Keep") { runner.apply(task.id) }.buttonStyle(.borderedProminent)
            case .failed:
                Button("Log") { showLog.toggle() }
                if task.directory != nil && task.workspace == .copy { Button("Discard Copy") { runner.discard(task.id) } }
                Button("Retry") { runner.retry(task.id) }
            default:
                Button(showLog ? "Hide Log" : "Log") { showLog.toggle() }
                Button("Run Again") { runner.retry(task.id) }
                Button { runner.remove(task.id) } label: { Image(systemName: "xmark") }.help("Remove from the list")
            }
        }
    }

    private var log: String {
        let text = (try? String(contentsOf: TaskRunner.logURL(task), encoding: .utf8)) ?? "No output."
        return text.split(separator: "\n").suffix(300).map { Kapitsa.clean(String($0)) }.joined(separator: "\n")
    }
}

private struct DiffSheet: View {
    let task: AgentTask
    @ObservedObject var runner: TaskRunner
    @Environment(\.dismiss) private var dismiss
    @State private var diff = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.headline).lineLimit(1)
                    Text("\(task.changedFiles.count) files  ·  +\(task.insertions) −\(task.deletions)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Discard", role: .destructive) { runner.discard(task.id); dismiss() }
                Button(task.workspace == .copy ? "Apply to Project" : "Keep") { runner.apply(task.id); dismiss() }.buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(6000).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(line))
                    }
                }.textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .padding(22).frame(minWidth: 820, minHeight: 540)
        .task { diff = await runner.diff(task) }
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
