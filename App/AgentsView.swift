import SwiftUI

struct AgentsView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @State private var commandState = Kapitsa.commandState
    @AppStorage("agentModelPath") private var agentModelPath = ""

    var body: some View {
        PageScaffold(title: "Agents", subtitle: "Launch coding agents against the local model. If no model is running, the default model loads first.") {
            modelCard
            if let launching = store.launching {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(launching).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Coding Agents", detail: "Opens in \(terminalName)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(Agents.catalog) { AgentCard(agent: $0, store: store) }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Integrations")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], spacing: 16) {
                    terminalCard
                    otherAppsCard
                }
            }
        }
        .onAppear { commandState = Kapitsa.commandState }
    }

    private var terminalName: String { Prefs.terminal == "ghostty" && Agents.ghostty != nil ? "Ghostty" : "Terminal" }

    private var modelCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Model").font(.headline)
                Text("Loaded automatically when an agent launches.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Picker("Default Model", selection: $agentModelPath) {
                Text(automaticLabel).tag("")
                Divider()
                ForEach(store.runnable) { model in
                    Text(label(for: model)).tag(model.path)
                }
            }.labelsHidden().frame(minWidth: 200, idealWidth: 320, maxWidth: 320)
        }.card()
    }

    private var automaticLabel: String {
        guard let model = store.agentModel else { return "Automatic" }
        return "Automatic (\(model.name))"
    }

    private func label(for model: LocalModel) -> String {
        guard let result = store.benchmark(for: model) else { return model.name }
        guard result.toolsPass else { return model.name + "  (no tool calling)" }
        return model.name + String(format: "  (%.0f tok/s)", result.writing ?? 0)
    }

    private var binOnPath: Bool {
        let bin = Kapitsa.commandURL.deletingLastPathComponent().path
        return Kapitsa.loginPath.split(separator: ":").map(String.init).contains(bin)
    }

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Command-Line Tool", systemImage: "apple.terminal").font(.headline)
            Text("Installs `kapitsa` to ~/.local/bin. Run `kapitsa claude`, `kapitsa opencode`, `kapitsa codex` or `kapitsa pi` in any project to start an agent on the running model.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                switch commandState {
                case "installed": Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case "foreign": Label("Conflicting command in ~/.local/bin", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                default: EmptyView()
                }
                Spacer()
                Button(commandState == "installed" ? "Reinstall" : commandState == "outdated" ? "Update" : "Install") {
                    do {
                        try Kapitsa.installCommand()
                        commandState = Kapitsa.commandState
                        store.notice = "Command-line tool installed. Open a new terminal window to use it."
                    } catch { store.errorMessage = error.localizedDescription }
                }.disabled(commandState == "foreign")
            }
            if !binOnPath {
                Text("~/.local/bin is not on your PATH. Add `export PATH=\"$HOME/.local/bin:$PATH\"` to ~/.zshrc.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(minHeight: 170, alignment: .top).card()
    }

    private var otherAppsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("API Endpoints", systemImage: "link").font(.headline)
            CopyRow(label: "OpenAI Base URL", value: "http://127.0.0.1:\(server.port)/v1")
            CopyRow(label: "Anthropic Base URL", value: "http://127.0.0.1:\(server.port)")
            CopyRow(label: "API Key", value: Prefs.apiKey.isEmpty ? "local" : Prefs.apiKey)
            CopyRow(label: "Model ID", value: server.record?.apiId)
        }.frame(minHeight: 170, alignment: .top).card()
    }
}

private struct AgentCard: View {
    let agent: AgentInfo
    @ObservedObject var store: AppStore

    var body: some View {
        let installed = store.agents[agent.id] != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AgentIcon(agent: agent, active: installed, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.title3.weight(.semibold))
                    Text(agent.maker + (installed ? "  ·  " + version : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Installed") }
            }
            Text(agent.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            if installed {
                HStack(spacing: 8) {
                    Button { store.launch(agent.id) } label: { Label("Open Project…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.launching != nil)
                    let recent = Prefs.recentProjects
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { project in
                                Button(project.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) {
                                    store.launch(agent.id, project: URL(fileURLWithPath: project))
                                }
                            }
                        } label: { Label("Recent", systemImage: "clock.arrow.circlepath") }
                            .fixedSize().controlSize(.large).disabled(store.launching != nil)
                    }
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(agent.install).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.copy(agent.install, "Install command copied.") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy Install Command")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    HStack {
                        Link("Website ↗", destination: agent.homepage).font(.caption)
                        Spacer()
                        Button("Refresh") { Task { await store.scan() } }.controlSize(.small)
                    }
                }
            }
        }.frame(minHeight: 196, alignment: .top).card()
    }

    private var version: String {
        let text = store.agentVersions[agent.id] ?? ""
        return text.split(separator: " ").first.map { "v" + String($0) } ?? "installed"
    }
}
