import SwiftUI

struct HomeView: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared

    var body: some View {
        PageScaffold(title: "Kapitsa Library", subtitle: "Local inference for coding agents, on your Mac.") {
            if let problem = Kapitsa.storageProblem() {
                Label(problem, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).card()
            }
            ServerCard(store: store, server: server)
            if store.runnable.isEmpty && !store.scanning { GetStarted(store: store) }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Coding Agents", detail: agentDetail)
                if let launching = store.launching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(launching).foregroundStyle(.secondary) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(Agents.catalog) { AgentLaunchTile(agent: $0, store: store) }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "System")
                HStack(alignment: .top, spacing: 14) {
                    MemoryGauge().frame(maxHeight: .infinity, alignment: .top).card()
                    ConnectCard(server: server).frame(maxHeight: .infinity, alignment: .top).card()
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentDetail: String {
        if server.phase == .ready, let record = server.record { return "Connected to \(record.modelName)" }
        if let model = store.agentModel { return "Default model: \(model.name)" }
        return "Requires a downloaded model"
    }
}

private struct ServerCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var server: ServerController

    var title: String {
        switch server.phase {
        case .ready: return server.record?.modelName ?? "Running"
        case .starting: return "Loading \(server.record?.modelName ?? "model")…"
        case .stopping: return "Stopping…"
        case .external: return "External Server Detected"
        case .failed: return "Failed to Start"
        case .stopped: return "No Model Loaded"
        }
    }

    var suggestion: LocalModel? {
        if let path = Prefs.lastModel, let model = store.model(at: path) { return model }
        return store.agentModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                StatusDot(server: server).scaleEffect(1.5).frame(width: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold)).lineLimit(1)
                    subtitle.font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 20)
                actions
            }
            if server.owned {
                Divider()
                LiveStats(server: server)
            }
        }.card(padding: 24)
    }

    @ViewBuilder private var subtitle: some View {
        if let record = server.record {
            Text("\(contextSummary(record))  ·  127.0.0.1:\(String(record.port))  ·  \(record.apiId)")
        } else if case .failed(let reason) = server.phase {
            Text(reason)
        } else if server.phase == .external {
            Text("Port \(String(server.externalPort))  ·  Managed outside this app")
        } else if let model = suggestion {
            Text(model.name + speedNote(model))
        } else {
            Text("Load a model to start the local API server.")
        }
    }

    /// "128K context, 44.6K fits in memory" when Kapitsa's budget holds less than the context asked for.
    private func contextSummary(_ record: ServerRecord) -> String {
        let asked = "\(record.context.uppercased()) context"
        guard let usable = server.stats.usableContext, let full = server.stats.context, usable < full else { return asked }
        return asked + ", " + Self.tokens(usable) + " fits in memory"
    }

    static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fK", Double(count) / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(count)"
    }

    private func speedNote(_ model: LocalModel) -> String {
        guard let speed = store.benchmark(for: model)?.writing else { return "" }
        return String(format: "  ·  %.0f tok/s", speed)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            if server.owned {
                Button("Logs") { store.showLog = true }
                Button("Stop", role: .destructive) { server.stop() }.disabled(server.phase == .stopping)
            }
            if server.phase == .ready || server.phase == .external {
                Button("Open Chat") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(server.port)")!) }
                    .buttonStyle(.borderedProminent)
            } else if !server.running {
                Button("Choose Model…") { store.page = .models }
                if let model = suggestion {
                    Button("Load Model") { store.load(model, context: model.contexts.contains(Prefs.lastContext) ? Prefs.lastContext : nil) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }.controlSize(.large)
    }
}

private struct GetStarted: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Get Started", detail: "Download a recommended model or add an existing model folder.")
            if let pick = store.recommended, let family = store.catalog.first(where: { $0.id == pick.family }) {
                RecommendedCard(family: family, variant: pick)
            } else if let error = store.catalogError {
                Text(error).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button { store.page = .discover } label: { Label("Browse Catalog", systemImage: "sparkle.magnifyingglass") }
                Button { store.addLibrary() } label: { Label("Add Model Folder…", systemImage: "folder.badge.plus") }
            }.controlSize(.large)
        }
    }
}

/// The catalog model suggested for this Mac, used on Home and Discover.
struct RecommendedCard: View {
    let family: CatalogFamily
    let variant: CatalogVariant
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if let job = downloads.jobs[variant.id], job.showsProgress { DownloadProgressLine(job: job) }
        }.card(padding: 22)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "star.fill").font(.title2).foregroundStyle(.yellow)
                .frame(width: 48, height: 48).background(Circle().fill(Color.yellow.opacity(0.14)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Recommended for Your Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(family.title).font(.title3.weight(.semibold))
                    Text("\(variant.variant) · \(String(format: "%.1f GB", variant.gigabytes))").foregroundStyle(.secondary).monospacedDigit()
                }
                Text(family.about).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 16)
            VariantAction(variant: variant, prominent: true)
        }
    }
}

struct AgentLaunchTile: View {
    let agent: AgentInfo
    @ObservedObject var store: AppStore

    var body: some View {
        let installed = store.agents[agent.id] != nil
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentIcon(agent: agent, active: installed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.headline).lineLimit(1)
                    Text(status(installed)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if installed {
                HStack(spacing: 6) {
                    Button { store.launch(agent.id) } label: {
                        Label("Launch", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(store.launching != nil)
                    let recent = Prefs.recentProjects
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { path in
                                Button(URL(fileURLWithPath: path).lastPathComponent) { store.launch(agent.id, project: URL(fileURLWithPath: path)) }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Recent Projects")
                    }
                }
            } else {
                Button { store.page = .agents } label: { Text("Set Up").frame(maxWidth: .infinity) }
            }
        }.card(padding: 16)
    }

    private func status(_ installed: Bool) -> String {
        guard installed else { return "Not installed" }
        let version = store.agentVersions[agent.id] ?? ""
        let number = version.split(separator: " ").first.map(String.init) ?? ""
        return number.isEmpty ? "Installed" : "v\(number)"
    }
}

private struct ConnectCard: View {
    @ObservedObject var server: ServerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("API Endpoint", systemImage: "link").font(.headline)
            CopyRow(label: "Base URL", value: "http://127.0.0.1:\(server.port)/v1")
            CopyRow(label: "API Key", value: server.apiKey.isEmpty ? "local" : server.apiKey)
            CopyRow(label: "Model ID", value: server.record?.apiId)
            Text("OpenAI and Anthropic compatible: Chat Completions, Responses and Messages.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
