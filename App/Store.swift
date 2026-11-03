import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, discover, models, agents, benchmarks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .models: return "My Models"
        case .agents: return "Agents"
        case .benchmarks: return "Benchmarks"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .discover: return "sparkle.magnifyingglass"
        case .models: return "square.stack.3d.up"
        case .agents: return "terminal"
        case .benchmarks: return "gauge.with.dots.needle.67percent"
        }
    }
}

/// App-wide state shared by the main window and the menu bar.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var page = Page.home
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var libraries = Prefs.libraries
    @Published private(set) var agents: [String: String] = [:]
    @Published private(set) var agentVersions: [String: String] = [:]
    @Published private(set) var catalog: [CatalogFamily] = []
    @Published private(set) var catalogError: String?
    @Published private(set) var benchmarks: [BenchResult] = []
    @Published private(set) var scanning = false
    @Published var selectedModelID: String? = UserDefaults.standard.string(forKey: "selectedModel")
    @Published var context = Prefs.lastContext
    @Published var notice = ""
    @Published var errorMessage: String?
    @Published var showLog = false
    @Published var importTarget: LocalModel?
    @Published private(set) var launching: String?
    /// Models being moved to another folder, with how far each move has got.
    @Published private(set) var relocations: [String: Double] = [:]

    let server = ServerController.shared
    private var booted = false

    private init() {
        Downloads.shared.finished = { [weak self] spec in
            Task { await self?.scan(); self?.notice = "\(spec) downloaded." }
        }
    }

    func bootstrap() async {
        guard !booted else { return }
        booted = true
        await scan()
        await loadCatalog()
        if Prefs.autoStart, !server.running, let path = Prefs.lastModel, let model = model(at: path) {
            load(model, context: model.contexts.contains(Prefs.lastContext) ? Prefs.lastContext : (model.contexts.dropLast().last ?? "max"))
        }
    }

    // MARK: Library

    var downloadsPath: String { Kapitsa.downloads.path }
    var runnable: [LocalModel] { models.filter(\.loadable) }
    var selected: LocalModel? { models.first { $0.id == selectedModelID } }
    func model(at path: String) -> LocalModel? { models.first { $0.path == path } }
    func libraryTitle(_ path: String) -> String { path == downloadsPath ? "Downloaded" : URL(fileURLWithPath: path).lastPathComponent }
    var allLibraries: [String] { [downloadsPath] + libraries }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let roots = allLibraries, verified = Registry.load()
        models = await Task.detached { ModelScanner.scan(libraries: roots, verified: verified) }.value
        let found = await Task.detached { Agents.installed() }.value
        agents = found
        let current = models
        benchmarks = await Task.detached { BenchmarkStore.load(models: current) }.value
        if selected == nil { selectedModelID = runnable.first?.id ?? models.first?.id }
        clampContext()
        Task {
            var versions: [String: String] = [:]
            for (name, path) in found { versions[name] = await Task.detached { Agents.version(path) }.value }
            agentVersions = versions
        }
    }

    func loadCatalog() async {
        do {
            catalog = try await Task.detached { try Catalog.load() }.value
            catalogError = nil
        } catch { catalogError = error.localizedDescription }
    }

    var recommended: CatalogVariant? { Catalog.recommended(catalog) }

    func localModel(for variant: CatalogVariant) -> LocalModel? { model(at: variant.folder.path) }

    func benchmark(for model: LocalModel) -> BenchResult? { BenchmarkStore.best(benchmarks, for: model) }

    func clampContext() {
        guard let model = selected, model.loadable, !model.contexts.contains(context) else { return }
        context = model.contexts.dropLast().last ?? "max"
    }

    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders containing models. Subfolders are scanned for MLX models and GGUF files."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !libraries.contains(url.path) { libraries.append(url.path) }
        Prefs.libraries = libraries
        page = .models
        Task { await scan() }
    }

    func removeLibrary(_ path: String) {
        libraries.removeAll { $0 == path }
        Prefs.libraries = libraries
        Task { await scan() }
    }

    /// Downloaded models go to the Trash, so a mistake can be undone.
    func trash(_ model: LocalModel) {
        guard server.record?.modelPath != model.path else { errorMessage = "Stop the model before moving it to the Trash."; return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: model.path), resultingItemURL: nil)
            notice = "\(model.name) moved to the Trash."
            Task { await scan() }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Moves a model folder (and anything inside it, such as a bundled drafter) to a folder the user picks,
    /// keeps it in the library, and carries its verification and benchmark records over to the new path.
    func relocate(_ model: LocalModel) {
        guard server.record?.modelPath != model.path else { errorMessage = "Stop the model before moving it."; return }
        guard relocations[model.path] == nil else { return }
        if Downloads.shared.jobs.values.contains(where: { $0.busy && $0.folder?.standardizedFileURL.path == model.path }) {
            errorMessage = "Pause or finish the download before moving this model."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where to move \(model.name). It stays in your library."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let source = URL(fileURLWithPath: model.path)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard destination.standardizedFileURL.path != source.standardizedFileURL.path else { return }
        guard !destination.path.hasPrefix(source.path + "/") else { errorMessage = "Choose a folder outside the model itself."; return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "\(folder.lastPathComponent) already contains an item named \(source.lastPathComponent)."
            return
        }
        relocations[model.path] = 0
        Task {
            let total = max(1, await Task.detached { SystemMemory.allocatedBytes(source) }.value)
            let progress = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let done = await Task.detached { SystemMemory.allocatedBytes(destination) }.value
                    if relocations[model.path] != nil { relocations[model.path] = min(0.99, Double(done) / Double(total)) }
                }
            }
            defer { progress.cancel() }
            do {
                // Within a volume this is a rename; across volumes, a copy followed by removing the original.
                try await Task.detached { try FileManager.default.moveItem(at: source, to: destination) }.value
                relocations[model.path] = nil
                Registry.move(from: model.path, to: destination.path)
                BenchmarkStore.move(from: model.path, to: destination.path)
                if Prefs.lastModel == model.path { Prefs.lastModel = destination.path }
                if Prefs.agentModel == model.path { Prefs.agentModel = destination.path }
                if !allLibraries.contains(where: { destination.path.hasPrefix($0 + "/") }) {
                    libraries.append(folder.path)
                    Prefs.libraries = libraries
                }
                await scan()
                selectedModelID = ModelScanner.identity(destination.path)
                notice = "\(model.name) moved to \(folder.path)."
            } catch {
                relocations[model.path] = nil
                // A failed copy across volumes can leave a partial folder; the original is still intact.
                if FileManager.default.fileExists(atPath: source.path), FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                errorMessage = "Couldn’t move \(model.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Server

    func load(_ model: LocalModel, context: String? = nil) {
        do {
            try server.start(model, context: context ?? self.context)
            notice = "Loading \(model.name)…"
        } catch { errorMessage = error.localizedDescription }
    }

    func loadLast() {
        guard let path = Prefs.lastModel, let model = model(at: path) else { page = .models; return }
        load(model, context: model.contexts.contains(Prefs.lastContext) ? Prefs.lastContext : nil)
    }

    func verify(_ model: LocalModel) async {
        do {
            let took = try await server.verify(model)
            await scan()
            notice = "\(model.name) verified (\(took))."
        } catch { errorMessage = error.localizedDescription }
    }

    func runBenchmark(_ model: LocalModel) {
        do {
            try BenchmarkRunner.shared.run(model) { [weak self] in Task { await self?.scan() } }
            page = .benchmarks
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Agents

    /// The model agents start with when none is running: the chosen one, else the last loaded, else the
    /// largest model that fits and passed the tool-call benchmark (capability matters more than speed for
    /// coding), else the largest that fits.
    var agentModel: LocalModel? {
        if let path = Prefs.agentModel, let model = model(at: path), model.loadable { return model }
        if let path = Prefs.lastModel, let model = model(at: path), model.loadable { return model }
        let fitting = runnable.filter { SystemMemory.estimatedNeedGB($0) < SystemMemory.totalGB * 0.7 }
        let capable = fitting.filter { benchmark(for: $0)?.toolsPass == true }
        return (capable.isEmpty ? fitting : capable).max { $0.size < $1.size }
    }

    func chooseProject() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Select the project folder for the agent."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func launch(_ agent: String, project: URL? = nil) {
        guard let project = project ?? chooseProject() else { return }
        guard agents[agent] != nil else {
            errorMessage = "\(Agents.displayName(agent)) is not installed. See Agents for installation."
            page = .agents
            return
        }
        Task {
            do {
                if !(server.phase == .ready || server.phase == .external) {
                    guard let model = agentModel else {
                        errorMessage = "No model available. Download one from Discover or add a model folder."
                        page = .discover
                        return
                    }
                    if !server.running {
                        launching = "Starting \(model.name) for \(Agents.displayName(agent))…"
                        try server.start(model, context: model.contexts.contains("64k") ? "64k" : (model.contexts.dropLast().last ?? "max"))
                    }
                    defer { launching = nil }
                    while server.phase == .starting {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    guard server.phase == .ready else {
                        errorMessage = "Model failed to start. \(Agents.displayName(agent)) was not launched. See Logs for details."
                        return
                    }
                }
                try Agents.launch(agent, project: project, port: server.port)
                notice = "\(Agents.displayName(agent)) launched in \(project.lastPathComponent)."
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func copy(_ text: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = message
    }
}
