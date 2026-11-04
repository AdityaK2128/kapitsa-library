import SwiftUI

/// Open coding models from Hugging Face that Kapitsa runs with speculative decoding, picked for agent work.
/// Each is an MLX build that keeps the model's MTP head (Kapitsa drafts with it), or one paired with a DFlash2
/// drafter repository that goes into its dflash2/ folder, the layout Kapitsa's own catalog uses. A pick is
/// listed only once Kapitsa was seen speeding it up. Scores are the makers' published figures.
struct CodingPick: Identifiable {
    struct Score: Hashable {
        let benchmark: String
        let value: Double
        /// The same benchmark for a well-known model of similar size, for scale.
        let baseline: Double
        let baselineName: String
    }

    let id: String          // the model repository, what `kapitsa pull` takes
    let name: String
    let maker: String
    let about: String
    let isMoE: Bool
    let modelGB: Double
    /// nil when the build's own MTP head does the drafting.
    let drafter: Downloads.Companion?
    let drafterGB: Double
    let license: String
    let scores: [Score]
    let source: URL

    var gigabytes: Double { modelGB + drafterGB }
    var folder: URL { Kapitsa.downloads.appendingPathComponent(id.replacingOccurrences(of: "/", with: "--")) }
    /// Downloaded once the library scan finds the model loadable (weights, tokenizer and every indexed shard,
    /// not just a config.json an interrupted download left) and, for a pick with a drafter, paired with a
    /// drafter in its folder that has weights.
    @MainActor func complete(in store: AppStore) -> Bool {
        guard let model = store.model(at: folder.path), model.loadable else { return false }
        guard let drafter else { return true }
        let path = folder.appendingPathComponent(drafter.into).path
        return model.drafter == path && SystemMemory.folderWeightsGB(path) > 0
    }
}

enum CodingPicks {
    static let all: [CodingPick] = [
        // Verified: Kapitsa loads it with MTP speculative decoding (depth 4) and passes its tool-call test;
        // kapitsa bench measured 1.7× the plain-decoding speed of the same model without the MTP head.
        CodingPick(
            id: "mlx-works/Ornith-1.5-9B-oQ4e-mtp", name: "Ornith 1.5 9B", maker: "Ornith AI",
            about: "A dense 9B for coding agents on the Qwen3.5 architecture that codes close to models four times its size. This MLX build keeps the MTP head, so Kapitsa drafts ahead with it.",
            isMoE: false, modelGB: 6.25, drafter: nil, drafterGB: 0,
            license: "MIT",
            scores: [
                .init(benchmark: "SWE-bench Verified", value: 70.6, baseline: 53.2, baselineName: "Qwen3.5 9B"),
                .init(benchmark: "Terminal-Bench 2.1 in Claude Code", value: 47.0, baseline: 18.9, baselineName: "Qwen3.5 9B"),
                .init(benchmark: "SWE-bench Pro", value: 47.5, baseline: 31.3, baselineName: "Qwen3.5 9B"),
            ],
            source: URL(string: "https://huggingface.co/ornith-ai/Ornith-1.5-9B")!),
    ]
}

/// The picks, shown in Discover under the Kapitsa catalog.
struct CodingPicksSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "More for Coding Agents",
                          detail: "Open coding models from Hugging Face that Kapitsa speeds up with speculative decoding. Scores are the makers’ published results.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(CodingPicks.all) { PickCard(pick: $0) }
            }
        }
    }
}

private struct PickCard: View {
    let pick: CodingPick
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var store = AppStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pick.name).font(.headline)
                if pick.isMoE { Badge(text: "MoE", color: .purple) }
                Badge(text: pick.drafter == nil ? "MTP" : "DFlash2", color: .blue)
                    .help(pick.drafter == nil ? "Kapitsa drafts ahead with the model’s own MTP head" : "Downloads with a DFlash2 drafter that Kapitsa drafts ahead with")
                Spacer()
                Text(pick.maker).font(.caption).foregroundStyle(.tertiary)
            }
            Text(pick.about).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(pick.scores, id: \.self) { score in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(score.benchmark).font(.caption)
                            Spacer()
                            Text(String(format: "%.1f", score.value)).font(.caption.weight(.semibold)).monospacedDigit()
                            Text(String(format: "vs %.1f", score.baseline)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                                .help("\(score.baselineName): \(String(format: "%.1f", score.baseline))")
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: proxy.size.width * score.baseline / 100)
                                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * score.value / 100).opacity(0.85)
                            }
                        }.frame(height: 4)
                    }
                }
                Text("Grey bars: \(Set(pick.scores.map(\.baselineName)).sorted().joined(separator: ", ")) on the same benchmark.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f GB", pick.gigabytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .help(pick.drafter == nil ? "Includes the MTP head" : String(format: "Model %.1f GB + drafter %.1f GB", pick.modelGB, pick.drafterGB))
                        FitBadge(gigabytes: pick.gigabytes)
                    }
                    HStack(spacing: 10) {
                        Text(pick.license).font(.caption2).foregroundStyle(.tertiary)
                        Link("Model card ↗", destination: pick.source).font(.caption2)
                    }
                }
                Spacer(minLength: 8)
                action
            }
            if let job = downloads.jobs[pick.id], job.showsProgress { DownloadProgressLine(job: job) }
        }.card()
    }

    @ViewBuilder private var action: some View {
        let job = downloads.jobs[pick.id]
        let bytes = Int64(pick.gigabytes * 1e9)
        switch job?.state {
        case .preparing?, .running?:
            Button("Pause") { downloads.pause(pick.id) }
        case .pausing?:
            Button("Pausing…") {}.disabled(true)
        case .paused?, .failed?:
            Button(job?.state == .paused ? "Resume" : "Retry") { start(bytes) }
        default:
            // Download jobs live only in memory; after a restart the scan decides, as for the catalog.
            if job?.state == .finished || pick.complete(in: store) {
                Label("Downloaded", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else if FileManager.default.fileExists(atPath: pick.folder.path) {
                Button("Resume") { start(bytes) }.help("Finish the model and its drafter")
            } else {
                Button("Download") { start(bytes) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func start(_ bytes: Int64) {
        downloads.start(pick.id, title: pick.name, expectedBytes: bytes, companion: pick.drafter)
    }
}
