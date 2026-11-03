import AppKit
import ServiceManagement
import SwiftUI

struct MainWindow: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { store.page }, set: { if let page = $0 { store.page = page } })) {
                ForEach(Page.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch store.page {
                    case .home: HomeView()
                    case .discover: DiscoverView()
                    case .models: ModelsView()
                    case .agents: AgentsView()
                    case .benchmarks: BenchmarksView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !store.notice.isEmpty {
                    Divider()
                    HStack {
                        Text(store.notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button { store.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onChange(of: store.selectedModelID) { _, id in
            UserDefaults.standard.set(id, forKey: "selectedModel")
            store.clampContext()
        }
        .onChange(of: server.phase) { _, phase in
            switch phase {
            case .ready: store.notice = "Model ready."
            case .failed: store.notice = "Model failed to start. See Logs for details."
            case .stopped: store.notice = "Model stopped."
            default: break
            }
        }
        .alert("Nearloop", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert(item: $store.launchWarning) { warning in
            Alert(title: Text("Not enough context for \(Agents.displayName(warning.agent))"), message: Text(warning.message),
                  primaryButton: .default(Text("Launch Anyway")) { store.launch(warning.agent, project: warning.project, force: true) },
                  secondaryButton: .cancel())
        }
        .sheet(isPresented: $store.showLog) { LogSheet() }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !downloads.active.isEmpty {
                ForEach(downloads.active) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(job.title).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(job.state == .pausing ? "Pausing" : String(format: "%.0f%%", job.fraction * 100))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.fraction).controlSize(.small)
                    }
                }
                Divider()
            }
            HStack(spacing: 8) {
                StatusDot(server: server)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.record?.modelName ?? (server.phase == .external ? "External Server" : "No Model Loaded"))
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(server.phase == .ready ? "Port \(server.port)" : server.phase == .starting ? "Loading…" : "Idle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if server.owned {
                    Button { server.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop Model")
                }
            }
        }.padding(12)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(server.record.map { "\($0.modelName) — \(server.phase == .ready ? "Running" : "Loading")" } ?? (server.phase == .external ? "External Server Running" : "No Model Loaded"))
        Divider()
        if server.owned {
            Button("Stop Model") { server.stop() }
        } else if !server.running, let path = Prefs.lastModel, let model = store.model(at: path) {
            Button("Load \(model.name)") { store.loadLast() }
        }
        if server.phase == .ready || server.phase == .external {
            Button("Open Chat") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(server.port)")!) }
            Button("Copy API URL") { store.copy("http://127.0.0.1:\(server.port)/v1", "API URL copied.") }
        }
        Divider()
        Menu("Launch Agent") {
            ForEach(Agents.catalog.filter { store.agents[$0.id] != nil }) { agent in
                Menu(agent.name) {
                    Button("Open Project…") { NSApp.activate(ignoringOtherApps: true); store.launch(agent.id) }
                    ForEach(Prefs.recentProjects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { store.launch(agent.id, project: URL(fileURLWithPath: path)) }
                    }
                }
            }
            if store.agents.isEmpty { Text("No Agents Installed") }
        }
        Divider()
        Button("Open Nearloop") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Nearloop") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The app icon's K monogram as a menu bar template glyph: the bob is filled while a model is running.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Map the icon's 1024-point drawing grid onto an 18-point glyph, centred.
            let scale: CGFloat = 16 / 536, originX: CGFloat = 217.6, originY: CGFloat = 210.5
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - originX) * scale, y: (y - originY) * scale) }
            func stroke(_ a: NSPoint, _ b: NSPoint, _ width: CGFloat) {
                let path = NSBezierPath()
                path.move(to: a); path.line(to: b)
                path.lineWidth = width; path.lineCapStyle = .round
                path.stroke()
            }
            NSColor.black.set()
            NSBezierPath(roundedRect: NSRect(origin: point(318, 262), size: NSSize(width: 96 * scale, height: 500 * scale)),
                         xRadius: 26 * scale, yRadius: 26 * scale).fill()
            stroke(point(440, 500), point(660, 290), 92 * scale)
            stroke(point(424, 520), point(612, 676), 1.5)
            let radius = 74 * scale
            let centre = point(646, 706)
            if active {
                NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).fill()
            } else {
                let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - radius + 0.6, y: centre.y - radius + 0.6, width: radius * 2 - 1.2, height: radius * 2 - 1.2))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("port") private var port = 8000
    @AppStorage("slots") private var slots = 1
    @AppStorage("diskCache") private var diskCache = "auto"
    @AppStorage("shareOnNetwork") private var share = false
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("terminalApp") private var terminal = "terminal"
    @AppStorage("runtimeFolder") private var runtime = ""
    @AppStorage("protectMemory") private var protect = true
    @AppStorage("memoryMargin") private var margin = 2.0
    @AppStorage("autoStartLastModel") private var autoStart = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var version = "…"

    var body: some View {
        TabView {
            Form {
                Toggle("Open at Login", isOn: Binding(get: { loginItem }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { AppStore.shared.errorMessage = error.localizedDescription }
                    loginItem = SMAppService.mainApp.status == .enabled
                }))
                Toggle("Load Last Model at Launch", isOn: $autoStart)
                Picker("Terminal Application", selection: $terminal) {
                    Text("Terminal").tag("terminal")
                    Text(Agents.ghostty == nil ? "Ghostty (Not Installed)" : "Ghostty").tag("ghostty")
                }
                Text("The server keeps running when the window is closed and remains available from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }

            Form {
                TextField("Port", value: $port, format: .number.grouping(.never))
                Stepper("Concurrent Requests: \(slots)", value: $slots, in: 1...4)
                Picker("Prompt Cache (SSD)", selection: $diskCache) {
                    Text("Automatic").tag("auto"); Text("2 GB").tag("2G"); Text("8 GB").tag("8G"); Text("16 GB").tag("16G"); Text("Off").tag("0")
                }
                Toggle("Allow Network Access", isOn: $share)
                SecureField("API Key", text: $apiKey, prompt: Text("Optional"))
                Text(share && apiKey.isEmpty ? "The server is reachable on your local network without authentication. Set an API key to require one."
                     : "Agents launched from this app use the key automatically. Changes take effect on next model load.")
                    .font(.caption).foregroundStyle(share && apiKey.isEmpty ? .orange : .secondary)
            }.formStyle(.grouped).tabItem { Label("Server", systemImage: "server.rack") }

            Form {
                Toggle("Memory Protection", isOn: $protect)
                Slider(value: $margin, in: 1...8, step: 0.5) { Text("Reserved for Other Apps: \(margin, specifier: "%.1f") GB") }.disabled(!protect)
                Text("Sizes Kapitsa’s memory budget around what your other apps are using, keeping this reserve free, so a model never drives macOS into heavy swapping. Models that don’t fit are declined with an explanation.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("System Memory", value: String(format: "%.0f GB total · %.0f GB available", SystemMemory.totalGB, SystemMemory.availableGB()))
            }.formStyle(.grouped).tabItem { Label("Memory", systemImage: "memorychip") }

            Form {
                LabeledContent("Data Location") {
                    HStack {
                        Text(runtime.isEmpty ? "~/.cache/kapitsa (default)" : runtime).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { runtime = url.path; Task { await AppStore.shared.scan() } }
                        }
                        if !runtime.isEmpty { Button("Reset") { runtime = ""; Task { await AppStore.shared.scan() } } }
                    }
                }
                Text("Stores downloads, converted models, prompt caches and temporary files. An external drive saves internal storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "externaldrive") }

            Form {
                LabeledContent("Engine Version", value: version)
                LabeledContent("Engine Path", value: Kapitsa.binary?.path ?? "Not Found")
                Text("Powered by Kapitsa, the open-source inference engine for Apple silicon by Nace AI, licensed under the Apache License 2.0. License and notices are included in the app bundle. This app is independent of the Kapitsa project.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link("Kapitsa on GitHub", destination: URL(string: "https://github.com/nace-ai/kapitsa")!)
                    Link("Published Benchmarks", destination: URL(string: "https://github.com/nace-ai/kapitsa#benchmarks")!)
                }.font(.callout)
            }.formStyle(.grouped).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
        .task { version = await Task.detached { Kapitsa.version() }.value }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppStore.shared.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let server = ServerController.shared
            BenchmarkRunner.shared.cancel()
            guard server.owned else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Stop Running Model?"
            alert.informativeText = "Quitting stops \(server.record?.modelName ?? "the model"). Connected agents and chats will disconnect."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            server.stopAndWait()
            return .terminateNow
        }
    }
}

@main
struct NearloopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var server = ServerController.shared

    init() { Prefs.migrate() }

    var body: some Scene {
        Window("Nearloop", id: "main") {
            MainWindow().tint(Color(red: 0.29, green: 0.55, blue: 0.76))
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Model Folder…") { AppStore.shared.addLibrary() }.keyboardShortcut("o")
            }
            CommandMenu("Go") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { AppStore.shared.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(nsImage: MenuBarIcon.image(active: server.phase == .ready))
        }
        Settings { SettingsView() }
    }
}
