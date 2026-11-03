import SwiftUI

struct DiscoverView: View {
    @ObservedObject var store = AppStore.shared
    @State private var source = 0

    var body: some View {
        PageScaffold(title: "Discover", subtitle: "Models optimized for Kapitsa. Downloads include speculative-decoding companions and resume automatically.") {
            Picker("Source", selection: $source) {
                Text("Kapitsa Catalog").tag(0)
                Text("Hugging Face").tag(1)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            if source == 0 { CatalogSection(store: store) } else { HuggingFaceSection() }
        }
    }
}

private struct CatalogSection: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.section) {
            if let error = store.catalogError {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await store.loadCatalog() } }
                }
            } else if store.catalog.isEmpty {
                ProgressView("Loading catalog…").frame(maxWidth: .infinity).padding(40)
            }
            if let pick = store.recommended, let family = store.catalog.first(where: { $0.id == pick.family }) {
                RecommendedCard(family: family, variant: pick)
            }
            if !store.catalog.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "All Models", detail: "\(store.catalog.count) model families · sizes shown on disk")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(store.catalog) { FamilyCard(family: $0) }
                    }
                }
                Text("Download location: \((Kapitsa.downloads.path as NSString).abbreviatingWithTildeInPath). Change in Settings › Storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct FamilyCard: View {
    let family: CatalogFamily
    @ObservedObject var downloads = Downloads.shared
    @State private var expanded = false

    var visible: [CatalogVariant] {
        expanded ? family.variants
            : family.variants.filter { $0.isDefault || $0.forSmallerMacs || $0.downloaded || downloads.jobs[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(family.title).font(.headline)
                if family.isMoE { Badge(text: "MoE", color: .purple) }
                Spacer()
                Text(family.alias).font(.caption.monospaced()).foregroundStyle(.tertiary).help("CLI alias: \(family.alias)")
            }
            Text(family.about.prefix(1).uppercased() + family.about.dropFirst())
                .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            Divider()
            VStack(spacing: 12) {
                ForEach(visible) { variant in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(variant.variant).font(.callout.monospaced())
                                    if variant.forSmallerMacs { Text("low-memory").font(.caption2).foregroundStyle(.tertiary) }
                                }
                                HStack(spacing: 10) {
                                    Text(String(format: "%.1f GB", variant.gigabytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    FitBadge(gigabytes: variant.gigabytes)
                                }
                            }
                            Spacer(minLength: 8)
                            VariantAction(variant: variant)
                        }
                        if let job = downloads.jobs[variant.id], job.showsProgress { DownloadProgressLine(job: job) }
                    }
                }
            }
            if family.variants.count > visible.count || expanded {
                Button(expanded ? "Show Less" : "Show All Variants (\(family.variants.count))") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.link).font(.caption)
            }
        }.card()
    }
}

private struct HuggingFaceSection: View {
    @State private var query = "MLX"
    @State private var results: [HuggingFace.Model] = []
    @State private var searching = false
    @State private var error = ""
    @State private var onlyCompatible = true

    var shown: [HuggingFace.Model] { results.filter { !onlyCompatible || $0.likelyCompatible } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search MLX models", text: $query).textFieldStyle(.plain).onSubmit(search)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                Button("Search", action: search).controlSize(.large).keyboardShortcut(.defaultAction)
            }
            HStack {
                Toggle("Kapitsa-compatible only", isOn: $onlyCompatible).toggleStyle(.checkbox)
                Spacer()
                if !results.isEmpty { Text("\(shown.count) of \(results.count) results").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Hugging Face downloads support Qwen3.5-family MLX models (4- to 8-bit or BF16). Other model families are available in the Kapitsa Catalog.")
                .font(.caption).foregroundStyle(.secondary)
            if searching { ProgressView().frame(maxWidth: .infinity).padding() }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            LazyVStack(spacing: 10) {
                ForEach(shown) { HuggingFaceRow(model: $0) }
            }
        }
        .task { if results.isEmpty { search() } }
    }

    func search() {
        searching = true
        error = ""
        Task {
            do { results = try await HuggingFace.search(query) } catch { self.error = error.localizedDescription }
            searching = false
        }
    }
}

private struct HuggingFaceRow: View {
    let model: HuggingFace.Model
    @ObservedObject var downloads = Downloads.shared
    @State private var details: HuggingFace.Details?
    @State private var checking = false

    var folder: URL { Kapitsa.downloads.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "--")) }
    var owner: String { String(model.id.split(separator: "/").first ?? "") }
    var name: String { String(model.id.split(separator: "/").last ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                summary
                Spacer(minLength: 12)
                action.controlSize(.regular).fixedSize()
            }
            if let job = downloads.jobs[model.id], job.showsProgress { DownloadProgressLine(job: job) }
        }.card(padding: 16)
    }

    private var summary: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Text(owner).font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 14) {
                    if let type = model.modelType { Text(type).font(.caption.monospaced()).foregroundStyle(model.likelyCompatible ? .green : .secondary) }
                    Label((model.downloads ?? 0).formatted(.number.notation(.compactName)), systemImage: "arrow.down").foregroundStyle(.secondary)
                    Label("\(model.likes ?? 0)", systemImage: "heart").foregroundStyle(.secondary)
                    if let details, details.bytes > 0 {
                        Text(String(format: "%.1f GB", Double(details.bytes) / 1e9)).monospacedDigit().foregroundStyle(.secondary)
                        FitBadge(gigabytes: Double(details.bytes) / 1e9)
                    }
                }.font(.caption).labelStyle(.titleAndIcon)
                if let problem = details?.problem { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
    }

    @ViewBuilder private var action: some View {
        let job = downloads.jobs[model.id]
        let expected = details?.bytes ?? job?.expected ?? 0
        // A job's state wins over the folder: a paused download already has some files on disk.
        switch job?.state {
        case .preparing?, .running?:
            Button("Pause") { downloads.pause(model.id) }
        case .pausing?:
            Button("Pausing…") {}.disabled(true)
        case .paused?:
            Button("Resume") { downloads.start(model.id, title: model.id, expectedBytes: expected) }
        case .failed?:
            Button("Retry") { downloads.start(model.id, title: model.id, expectedBytes: expected) }
        default:
            if job?.state == .finished || FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) {
                Label("Downloaded", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else if let details {
                Button("Download") { downloads.start(model.id, title: model.id, expectedBytes: details.bytes) }
                    .disabled(details.problem != nil)
            } else {
                verifyButton
            }
        }
    }

    private var verifyButton: some View {
            Button(checking ? "Verifying…" : "Verify") {
                checking = true
                Task {
                    details = try? await HuggingFace.details(model.id)
                    if details == nil { details = HuggingFace.Details(bytes: 0, problem: "Repository unavailable.") }
                    checking = false
                }
            }.disabled(checking || !model.likelyCompatible).help("Checks size and compatibility before downloading")
    }
}
