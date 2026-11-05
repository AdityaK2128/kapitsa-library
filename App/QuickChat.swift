import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Shortcut

/// A key with modifiers, as the user recorded it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (command, option, control, shift).
    var modifiers: UInt
    /// What the key prints, captured when it was recorded ("K", "Space").
    var key: String

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue, key: "Space")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// The key's name for display, from its code where it prints nothing useful.
    static func name(for event: NSEvent) -> String {
        let named: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_Escape: "Esc",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let name = named[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static var isFunctionKey: (UInt16) -> Bool = { code in
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(Int(code))
    }
}

/// The Quick Chat shortcut, registered with macOS as a system-wide hot key (Carbon's RegisterEventHotKey,
/// which needs no Accessibility permission). It works whenever Nearloop is running, window open or not.
@MainActor
final class QuickChatHotKey: ObservableObject {
    static let shared = QuickChatHotKey()

    @Published private(set) var shortcut: Shortcut
    @Published var enabled: Bool { didSet { Prefs.defaults.set(enabled, forKey: "quickChatEnabled"); register() } }
    /// Set when macOS refused the shortcut, usually because another app has it.
    @Published private(set) var problem: String?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {
        enabled = Prefs.defaults.object(forKey: "quickChatEnabled") as? Bool ?? true
        if let data = Prefs.defaults.data(forKey: "quickChatShortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func set(_ new: Shortcut) {
        shortcut = new
        if let data = try? JSONEncoder().encode(new) { Prefs.defaults.set(data, forKey: "quickChatShortcut") }
        register()
    }

    func register() {
        unregister()
        problem = nil
        guard enabled else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in QuickChatWindow.shared.toggle() }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4E524C50), id: 1)  // "NRLP"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            problem = status == eventHotKeyExistsErr
                ? "\(shortcut.display) is already used by another app or by macOS. Choose another shortcut."
                : "macOS didn’t accept \(shortcut.display) (error \(status)). Choose another shortcut."
        }
    }

    /// While a new shortcut is being recorded, the old one must not open the window.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}

/// A button that records a shortcut: click it, then press the keys. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var hotKey = QuickChatHotKey.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = ""

    var body: some View {
        HStack(spacing: 10) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press a shortcut…" : hotKey.shortcut.display)
                    .font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
                    .frame(minWidth: 130)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if hotKey.shortcut != .standard && !recording {
                Button("Reset") { hotKey.set(.standard) }.buttonStyle(.link)
            }
            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = ""
        hotKey.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // A plain letter would fire while typing anywhere; a modifier is needed, except for F-keys.
            guard !flags.subtracting(.shift).isEmpty || Shortcut.isFunctionKey(event.keyCode) else {
                hint = "Include ⌘, ⌥ or ⌃."
                return nil
            }
            hotKey.set(Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, key: Shortcut.name(for: event)))
            stop(registered: true)
            return nil
        }
    }

    private func stop(registered: Bool = false) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording && !registered { hotKey.register() }
        recording = false
    }
}

// MARK: - Window

/// A floating panel that can take keyboard input while another app stays in front, like Spotlight.
private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The Quick Chat window: appears over whatever is in front on the current Space, near the top of the
/// screen with the pointer, and goes away with Esc, the shortcut again, or a click elsewhere.
@MainActor
final class QuickChatWindow: NSObject, NSWindowDelegate {
    static let shared = QuickChatWindow()

    private var panel: QuickPanel?
    static let width: CGFloat = 680

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let height = panel.frame.height
            panel.setFrame(NSRect(x: visible.midX - Self.width / 2, y: visible.maxY - visible.height * 0.22 - height,
                                  width: Self.width, height: height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickChatShown, object: nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Grows downward from its top edge as the conversation appears, up to a height that fits the screen.
    func resize(to height: CGFloat) {
        guard let panel else { return }
        let limit = (panel.screen?.visibleFrame.height ?? 800) * 0.7
        let target = min(max(height, 60), limit)
        guard abs(panel.frame.height - target) > 1 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - target
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Continue in the main window, on the Chat page.
    func openInApp(_ id: UUID?) {
        hide()
        if let id { ChatStore.shared.selectedID = id }
        AppStore.shared.page = .chat
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Nearloop" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window was closed: opening the app again makes SwiftUI bring it back.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func make() -> QuickPanel {
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                               styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                               backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        let host = NSHostingView(rootView: QuickChatView().tint(Color(red: 0.29, green: 0.55, blue: 0.76)))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        // A click in another app puts it away, as Spotlight does; a reply keeps being written meanwhile.
        Task { @MainActor in self.hide() }
    }
}

extension Notification.Name {
    static let quickChatShown = Notification.Name("NearloopQuickChatShown")
}

// MARK: - View

struct QuickChatView: View {
    @ObservedObject var chat = ChatStore.shared
    @ObservedObject var server = ServerController.shared
    @ObservedObject var store = AppStore.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: chat.webSearch ? "sparkle.magnifyingglass" : "bubble.left").font(.system(size: 18)).foregroundStyle(.secondary)
                TextField("Ask anything", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($focused)
                    .onSubmit(send)
                if chat.busy && chat.generating == chat.quickID {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
                }
                Toggle(isOn: $chat.webSearch) { Image(systemName: "globe") }
                    .toggleStyle(.button).buttonStyle(.borderless).help("Search the web")
            }
            .padding(.horizontal, 18).frame(height: 60)
            if let conversation {
                Divider()
                thread(conversation)
                Divider()
                footer(conversation)
            }
        }
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
        .onExitCommand { QuickChatWindow.shared.hide() }
        .onReceive(NotificationCenter.default.publisher(for: .quickChatShown)) { _ in
            focused = true
            // An old Quick Chat is left in the history; the window opens empty again.
            if let conversation, Date().timeIntervalSince(conversation.updated) > 15 * 60, !chat.busy { chat.quickID = nil }
            fit()
        }
        .onChange(of: conversation?.messages.count ?? 0) { _, _ in fit() }
        .onAppear { focused = true; fit() }
    }

    private var conversation: Conversation? {
        chat.quickID.flatMap { id in chat.conversations.first { $0.id == id } }
    }

    private func fit() {
        QuickChatWindow.shared.resize(to: conversation == nil ? 60 : 520)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.busy else { return }
        chat.sendQuick(text)
        draft = ""
        fit()
    }

    private func thread(_ conversation: Conversation) -> some View {
        let shown = conversation.messages.filter { $0.role != .tool }
        let writing = chat.generating == conversation.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(shown) { message in
                        if message.role == .user {
                            UserBubble(message: message)
                        } else {
                            AssistantReply(message: message, live: writing && message.id == shown.last?.id,
                                           isLast: !writing && message.id == shown.last?.id, chat: chat, conversationID: conversation.id,
                                           sources: ChatStore.sources(for: message, in: conversation))
                        }
                    }
                    if let launching = store.launching, writing {
                        ProgressView(launching).controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: shown.last.map { $0.text.count + $0.reasoning.count + $0.steps.count } ?? 0) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func footer(_ conversation: Conversation) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(server.phase == .ready || server.phase == .external ? Color.green : server.phase == .starting ? .orange : .secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(modelName).lineLimit(1).truncationMode(.middle)
            }.foregroundStyle(.secondary)
            Spacer()
            Button("New Chat") { chat.quickID = nil; draft = ""; focused = true; fit() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open in Nearloop") { QuickChatWindow.shared.openInApp(conversation.id) }
                .keyboardShortcut("o", modifiers: .command)
        }
        .buttonStyle(.borderless).font(.caption)
        .padding(.horizontal, 18).frame(height: 34)
    }

    private var modelName: String {
        if let record = server.record, server.phase != .stopped { return record.modelName }
        if server.phase == .external { return "Server on port \(server.port)" }
        return store.quickChatModel.map { "\($0.name) loads when you ask" } ?? "No model"
    }
}

/// The frosted window background macOS uses for Spotlight-style panels.
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Settings

/// Settings › Quick Chat: the shortcut, and the model it loads when none is running.
struct QuickChatSettings: View {
    @ObservedObject var hotKey = QuickChatHotKey.shared
    @ObservedObject var store = AppStore.shared
    @ObservedObject var server = ServerController.shared
    @AppStorage("quickChatModel") private var quickModel = ""

    var body: some View {
        Form {
            Section {
                Toggle("Open Quick Chat with a Keyboard Shortcut", isOn: $hotKey.enabled)
                LabeledContent("Shortcut") { ShortcutRecorder() }.disabled(!hotKey.enabled)
                if let problem = hotKey.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try It Now") { QuickChatWindow.shared.show() }
            } footer: {
                Text("Press the shortcut in any app to ask the local model anything, with web search. Esc or a click elsewhere puts it away; your Quick Chats are saved with your other chats. It works while Nearloop is running, including from the menu bar with its window closed.")
            }
            Section {
                Picker("Model", selection: $quickModel) {
                    Text("Default Model" + (store.agentModel.map { " (\($0.name))" } ?? "")).tag("")
                    ForEach(store.runnable) { Text($0.name).tag($0.path) }
                }
                LabeledContent("Right Now") {
                    Text(current).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("When a model is already loaded, Quick Chat answers with it, so nothing reloads. When none is, it loads this one. Choose a small, fast model if you mostly ask quick questions.")
            }
        }
        .formStyle(.grouped)
    }

    private var current: String {
        if server.phase == .ready, let record = server.record { return "Uses \(record.modelName), which is loaded" }
        if server.phase == .external { return "Uses the server on port \(server.port)" }
        if server.phase == .starting { return "Loading \(server.record?.modelName ?? "a model")" }
        return store.quickChatModel.map { "Loads \($0.name) on your first question" } ?? "No model available. Download one from Discover."
    }
}
