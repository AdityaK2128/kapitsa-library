import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chat = ChatStore.shared
    @AppStorage("chatHistoryShown") private var historyShown = true
    @State private var historyPopover = false

    var body: some View {
        GeometryReader { proxy in
            // Room for the history column only when the conversation keeps a comfortable width beside it.
            let docked = proxy.size.width >= 820
            HStack(spacing: 0) {
                if docked && historyShown {
                    ChatHistory(chat: chat).frame(width: 250)
                        .background(Color.primary.opacity(0.025))
                    Divider()
                }
                VStack(spacing: 0) {
                    ChatHeader(chat: chat) {
                        if docked { withAnimation(.snappy) { historyShown.toggle() } } else { historyPopover.toggle() }
                    }
                    .popover(isPresented: $historyPopover, arrowEdge: .bottom) {
                        ChatHistory(chat: chat) { historyPopover = false }.frame(width: 300, height: 460)
                    }
                    Divider().opacity(0.6)
                    ChatThread(chat: chat)
                }
            }
        }
    }
}

// MARK: - Header and history

private struct ChatHeader: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    let toggleHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleHistory) { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).help("Show or Hide Chat History")
            Text(chat.selected?.title ?? "New Chat").font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 260, alignment: .trailing)
            .help(server.phase == .ready ? "The model answering this chat" : "Sending a message loads your default model")
            Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("New Chat (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).frame(height: 44)
    }

    private var model: String {
        switch server.phase {
        case .ready: return server.record?.modelName ?? "Model"
        case .external: return "Server on port \(server.port)"
        case .starting: return "Loading \(server.record?.modelName ?? "model")…"
        default: return "No model loaded"
        }
    }

    private var dot: Color {
        switch server.phase {
        case .ready, .external: return .green
        case .starting: return .orange
        default: return .secondary.opacity(0.5)
        }
    }
}

/// Past chats, newest first, grouped by when they were last used, with a search field.
private struct ChatHistory: View {
    @ObservedObject var chat: ChatStore
    var picked: () -> Void = {}
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search chats", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(12)
            if chat.conversations.isEmpty {
                Text("Your chats appear here. They stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                Spacer()
            } else if groups.isEmpty {
                Text("No chats match “\(query)”.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.title) { group in
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                            ForEach(group.chats) { row($0) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let renaming { chat.rename(renaming.id, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = conversation.id == chat.selectedID
        return Button {
            chat.selectedID = conversation.id
            picked()
        } label: {
            HStack(spacing: 6) {
                Text(conversation.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if chat.generating == conversation.id { ProgressView().controlSize(.mini) }
            }
            .font(.callout)
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18)
                                                               : hovered == conversation.id ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? conversation.id : (hovered == conversation.id ? nil : hovered) }
        .contextMenu {
            Button("Rename…") { newTitle = conversation.title; renaming = conversation }
            Button("Delete", role: .destructive) { chat.delete(conversation.id) }
        }
    }

    private var groups: [(title: String, chats: [Conversation])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let matching = query.isEmpty ? chat.conversations : chat.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.messages.contains { $0.role == .user && $0.text.localizedCaseInsensitiveContains(query) }
        }
        func bucket(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            switch days {
            case ...0: return "Today"
            case 1: return "Yesterday"
            case 2...7: return "Previous 7 Days"
            case 8...30: return "Previous 30 Days"
            default: return "Older"
            }
        }
        var order: [String] = []
        var buckets: [String: [Conversation]] = [:]
        for conversation in matching {
            let key = bucket(conversation.updated)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(conversation)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

// MARK: - Thread

private struct ChatThread: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    @ObservedObject var store = AppStore.shared

    var body: some View {
        if let conversation = chat.selected, !conversation.messages.isEmpty {
            VStack(spacing: 0) {
                messages(conversation)
                Composer(chat: chat)
            }
        } else {
            // A new chat: the greeting and the message box sit together in the middle, as in ChatGPT and Claude.
            VStack(spacing: 0) {
                Spacer()
                welcome
                Composer(chat: chat).padding(.top, 18)
                Spacer()
                Spacer()
            }
        }
    }

    private func messages(_ conversation: Conversation) -> some View {
        let shown = conversation.messages.filter { $0.role != .tool }
        let writing = chat.generating == conversation.id
        let lastAssistant = shown.last?.role == .assistant ? shown.last?.id : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(shown) { message in
                        if message.role == .user {
                            UserBubble(message: message)
                        } else {
                            AssistantReply(message: message, live: writing && message.id == shown.last?.id,
                                           isLast: !writing && message.id == lastAssistant, chat: chat)
                        }
                    }
                    // A question left without an answer, say because the model stopped or the app quit while it wrote.
                    if !writing, shown.last?.role == .user {
                        HStack(spacing: 10) {
                            Label("No reply.", systemImage: "exclamationmark.bubble").foregroundStyle(.secondary)
                            Button("Retry") { chat.regenerate() }.disabled(chat.busy)
                        }.font(.callout)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: shown.last.map { $0.text.count + $0.reasoning.count + $0.steps.count } ?? 0) { _, _ in
                if writing { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: shown.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text("What can I help with?").font(.system(size: 28, weight: .semibold))
            Text(modelLine).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let launching = store.launching {
                ProgressView(launching).controlSize(.small)
            } else if !server.running, let model = store.agentModel {
                Button("Load \(model.name)") {
                    Task { try? await store.ensureServer(purpose: "Chat", context: ChatStore.context) }
                }.buttonStyle(.borderedProminent)
            } else if !server.running {
                Button("Find a Model") { store.page = .discover }
            }
        }
        .padding(.horizontal, 28).frame(maxWidth: .infinity)
    }

    private var modelLine: String {
        if server.phase == .ready, let record = server.record { return "Chatting with \(record.modelName) on this Mac. Nothing you send leaves it, except web searches." }
        if server.phase == .external { return "Chatting with the server already running on port \(server.port)." }
        if server.phase == .starting { return "Loading \(server.record?.modelName ?? "the model")…" }
        if let model = store.agentModel { return "Send a message to load \(model.name), or load it now." }
        return "Download a model from Discover to start chatting."
    }
}

private struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 120, height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.16)))
                }
            }
        }
    }
}

private struct AssistantReply: View {
    let message: ChatMessage
    let live: Bool
    let isLast: Bool
    @ObservedObject var chat: ChatStore
    @State private var showThinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        if live && message.text.isEmpty && message.toolCalls.isEmpty { ProgressView().controlSize(.mini) }
                        Text(thinkingLabel).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(message.steps, id: \.callID) { StepRow(step: $0) }
            if !message.text.isEmpty {
                MarkdownText(text: message.text)
            } else if live && message.reasoning.isEmpty && message.steps.isEmpty {
                ProgressView().controlSize(.small)
            }
            if let error = message.error {
                Label(error, systemImage: error == "Stopped." ? "stop.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(error == "Stopped." ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !live && message.toolCalls.isEmpty && (!message.text.isEmpty || message.error != nil) {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingLabel: String {
        if let seconds = message.thinkingSeconds { return seconds < 1 ? "Thought briefly" : "Thought for \(Int(seconds.rounded())) s" }
        return "Thinking…"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if !message.text.isEmpty {
                Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
            }
            if isLast {
                Button { chat.regenerate() } label: { Image(systemName: "arrow.clockwise") }.help("Write the reply again").disabled(chat.busy)
            }
            if let tokens = message.outputTokens {
                Text("\(tokens.formatted()) tokens" + (message.tokensPerSecond.map { String(format: " · %.0f tok/s", $0) } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
    }
}

/// A web search or a page read, with what it found.
private struct StepRow: View {
    let step: ChatStep
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if !step.results.isEmpty { withAnimation(.snappy) { expanded.toggle() } } } label: {
                HStack(spacing: 7) {
                    if !step.done { ProgressView().controlSize(.mini) } else {
                        Image(systemName: step.error != nil ? "exclamationmark.triangle" : step.kind == .read ? "doc.text" : "magnifyingglass")
                            .foregroundStyle(step.error != nil ? Color.orange : Color.secondary)
                    }
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if !step.results.isEmpty {
                        Text("\(step.results.count) results").foregroundStyle(.tertiary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }.buttonStyle(.plain)
            if let error = step.error {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.leading, 10).fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.results, id: \.url) { result in
                        VStack(alignment: .leading, spacing: 1) {
                            if let url = URL(string: result.url) {
                                Link(result.title, destination: url).font(.callout).lineLimit(1)
                            }
                            Text(result.host).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }.padding(.leading, 12)
            }
        }
    }

    private var title: String {
        switch step.kind {
        case .search: return (step.done ? "Searched " : "Searching ") + "“\(step.subject)”"
        case .read: return (step.done ? "Read " : "Reading ") + (URL(string: step.subject)?.host?.replacingOccurrences(of: "www.", with: "") ?? step.subject)
        case .other: return step.subject
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Composer

private struct Composer: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var server = ServerController.shared
    @State private var draft = ""
    @State private var images: [Data] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                        ZStack(alignment: .topTrailing) {
                            if let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.white, .black.opacity(0.6)).offset(x: 5, y: -5)
                        }
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                // Sizes the editor to its text, up to about ten lines.
                Text(draft.isEmpty ? " " : draft + " ").font(.body).padding(.horizontal, 5).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).opacity(0)
                if draft.isEmpty {
                    Text("Message").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.body).scrollContentBackground(.hidden).focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends; Shift-Return (or Option-Return) starts a new line.
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        send()
                        return .handled
                    }
            }
            .frame(minHeight: 34, maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { attach() } label: { Image(systemName: "paperclip") }.buttonStyle(.borderless).help("Attach Images")
                Toggle(isOn: $chat.webSearch) { Label("Search", systemImage: "globe") }
                    .toggleStyle(.button).help("Let the model search the web and read pages (\(WebSearch.provider.title))")
                Toggle(isOn: $chat.thinking) { Label("Think", systemImage: "brain") }
                    .toggleStyle(.button).help("Let the model reason before answering; slower, often better")
                Spacer()
                if chat.busy {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).help("Stop").keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                        .disabled(!canSend).help("Send (Return)")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: 780)
        .padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 6)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            for provider in providers { load(provider) }
            return true
        }
        .onAppear { focused = true }
        .onChange(of: chat.selectedID) { _, _ in focused = true }
    }

    private var canSend: Bool { !chat.busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    private func send() {
        guard canSend else { return }
        chat.send(draft, images: images)
        draft = ""
        images = []
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images for the model to look at."
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap(ChatStore.jpeg(from:))
    }

    private func load(_ provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage, let data = ChatStore.jpeg(from: image) else { return }
                Task { @MainActor in images.append(data) }
            }
        } else {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = ChatStore.jpeg(from: url) else { return }
                Task { @MainActor in images.append(data) }
            }
        }
    }
}

// MARK: - Markdown

/// Renders the Markdown models write: headings, paragraphs, lists, quotes, tables and code blocks, with
/// inline bold, italics, code and links.
struct MarkdownText: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case item(String, marker: String, indent: Int)
        case quote(String)
        case code(String, language: String)
        case table([[String]])
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        case .item(let text, let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }.padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code, let language):
            CodeBlock(code: code, language: language)
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        case .rule:
            Divider()
        }
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    nonisolated static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""
        var table: [[String]] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flush()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line under a table's header.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            } else if !table.isEmpty {
                flush()
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(.heading(line[match].filter { $0 == "#" }.count, String(line[match.upperBound...])))
            } else if ["---", "***", "___"].contains(line) {
                flush(); blocks.append(.rule)
            } else if let match = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(String(line[match.upperBound...]), marker: "•", indent: indent))
            } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(String(line[match.upperBound...]), marker: line[match].trimmingCharacters(in: .whitespaces), indent: indent))
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        // A code block still being written shows as code.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"), language: language)) }
        flush()
        return blocks
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(12).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Settings

/// Settings › Chat: where web searches go.
struct ChatSettings: View {
    @AppStorage("searchProvider") private var provider = WebSearch.Provider.duckduckgo.rawValue
    @AppStorage("searchResults") private var results = 5
    @AppStorage("pageCharacters") private var pageCharacters = 12_000
    @AppStorage("searxngURL") private var searxng = ""
    @State private var braveKey = Keychain.read("braveSearchKey") ?? ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Picker("Web Search", selection: $provider) {
                ForEach(WebSearch.Provider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            switch WebSearch.Provider(rawValue: provider) ?? .duckduckgo {
            case .duckduckgo:
                Text("Free and needs no key. DuckDuckGo may ask to slow down after many searches; Brave Search or SearXNG avoid that.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .brave:
                SecureField("API Key", text: $braveKey, prompt: Text("From api-dashboard.search.brave.com"))
                    .onChange(of: braveKey) { _, key in Keychain.write("braveSearchKey", key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                Text("Kept in your login keychain.").font(.caption).foregroundStyle(.secondary)
            case .searxng:
                TextField("Server Address", text: $searxng, prompt: Text("http://localhost:8888"))
                Text("A SearXNG server with the JSON format turned on in its settings.yml.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Results per Search: \(results)", value: $results, in: 1...10)
            Picker("Page Length the Model Reads", selection: $pageCharacters) {
                Text("Short (6,000 characters)").tag(6_000)
                Text("Medium (12,000 characters)").tag(12_000)
                Text("Long (24,000 characters)").tag(24_000)
            }
            HStack {
                Button(testing ? "Searching…" : "Test Search") {
                    testing = true
                    Task {
                        switch await WebSearch.search("Apple silicon") {
                        case .success(let found): testResult = found.isEmpty ? "No results came back." : "Works: \(found.count) results."
                        case .failure(let failure): testResult = failure.message
                        }
                        testing = false
                    }
                }.disabled(testing)
                Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Searches and pages are fetched by Nearloop, not the model; only the search words leave this Mac. Pages on this Mac or a private network are never read. The web search design follows oMLX’s, under the Apache License 2.0.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}
