import Foundation

struct CatalogVariant: Identifiable, Hashable {
    let id: String          // e.g. qwen3.6-35b-a3b:4bit, what `kapitsa pull` takes
    let family: String
    let variant: String
    let alias: String
    let gigabytes: Double
    var isDefault = false
    var forSmallerMacs = false

    var folder: URL { Kapitsa.downloads.appendingPathComponent("\(family)-\(variant)") }
    var downloaded: Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) }
    var bytes: Int64 { Int64(gigabytes * 1e9) }
}

struct CatalogFamily: Identifiable, Hashable {
    let id: String
    var alias = ""
    var about = ""
    var format = ""
    var variants: [CatalogVariant] = []

    var title: String {
        id.split(separator: "-").map { part in
            let text = String(part)
            if text.first?.isNumber == true || text.count <= 3 { return text.uppercased() }
            return text.prefix(1).uppercased() + text.dropFirst()
        }.joined(separator: " ")
    }
    var defaultVariant: CatalogVariant? { variants.first(where: \.isDefault) ?? variants.first }
    var isMoE: Bool { about.localizedCaseInsensitiveContains("MoE") }
}

/// Kapitsa's model catalog, read from `kapitsa --help` (descriptions) and `kapitsa list` (every variant and size).
enum Catalog {

    static func load() throws -> [CatalogFamily] {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        let help = try Kapitsa.runSync(binary.path, ["--help"], env: Kapitsa.environment(), timeout: 20).output
        let list = try Kapitsa.runSync(binary.path, ["list"], env: Kapitsa.environment(), timeout: 30).output
        return parse(help: help, list: list)
    }

    static func parse(help: String, list: String) -> [CatalogFamily] {
        var families: [CatalogFamily] = []
        var smaller: [String: String] = [:]
        var defaults: [String: String] = [:]
        let header = try! NSRegularExpression(pattern: #"^  ([a-z0-9][\w.\-]*)\s+\(([^)]+)\)\s+[\d.]+ GB\s+(.+)$"#)
        var current: Int?
        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func group(_ i: Int) -> String { String(line[Range(match.range(at: i), in: line)!]) }
                families.append(CatalogFamily(id: group(1), alias: group(2), about: group(3)))
                current = families.count - 1
            } else if let index = current, line.hasPrefix(String(repeating: " ", count: 20)) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("also ") { continue }
                if families[index].format.isEmpty {
                    let id = families[index].id
                    defaults[id] = String(text.prefix { $0 != " " })
                    if let range = text.range(of: "smaller Macs: ") { smaller[id] = String(text[range.upperBound...].prefix { $0 != " " && $0 != ")" }) }
                    families[index].format = text.split(separator: ";").first.map(String.init) ?? text
                }
            } else if !line.hasPrefix(" ") {
                current = nil
            }
        }
        // `kapitsa list` prints downloaded models as rows ("  qwen3.8-27b:4bit    20.17 GB  weights + …") and
        // the rest on one line that starts "Available:" (or "Also available:" once something is downloaded).
        let entry = try! NSRegularExpression(pattern: #"([\w.\-]+):([\w.\-]+) \(([^,]+), ([\d.]+) GB\)"#)
        let downloaded = try! NSRegularExpression(pattern: #"^\s+([\w.\-]+):([\w.\-]+)\s+([\d.]+) GB\b"#, options: .anchorsMatchLines)
        var found: [(family: String, variant: String, alias: String, gigabytes: Double)] = []
        for match in downloaded.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
            func group(_ i: Int) -> String { String(list[Range(match.range(at: i), in: list)!]) }
            found.append((group(1), group(2), "", Double(group(3)) ?? 0))
        }
        let listLine = list.split(separator: "\n").first { $0.hasPrefix("Available:") || $0.hasPrefix("Also available:") }.map(String.init) ?? ""
        for match in entry.matches(in: listLine, range: NSRange(listLine.startIndex..., in: listLine)) {
            func group(_ i: Int) -> String { String(listLine[Range(match.range(at: i), in: listLine)!]) }
            found.append((group(1), group(2), group(3), Double(group(4)) ?? 0))
        }
        for row in found {
            let family = row.family, variant = row.variant
            let alias = row.alias.isEmpty ? (families.first { $0.id == family }?.alias ?? "") : row.alias
            var item = CatalogVariant(id: "\(family):\(variant)", family: family, variant: variant, alias: alias,
                                      gigabytes: row.gigabytes)
            item.isDefault = defaults[family] == variant
            item.forSmallerMacs = smaller[family] == variant
            if let index = families.firstIndex(where: { $0.id == family }) {
                families[index].variants.append(item)
            } else {
                families.append(CatalogFamily(id: family, variants: [item]))
            }
        }
        return families.filter { !$0.variants.isEmpty }
    }

    static func fits(_ variant: CatalogVariant) -> Bool { Kapitsa.fitLabel(gigabytes: variant.gigabytes).hasPrefix("Fits") }

    /// Whether Kapitsa's own description of a family presents it for coding or agents.
    static func codingOriented(_ family: CatalogFamily) -> Bool {
        family.about.range(of: #"\b(code|coder|coding|agent|agents|agentic|tool calls?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The model to suggest first on this Mac, decided from Kapitsa's catalog rather than a fixed list: the
    /// largest variant that fits this Mac's memory (each family's default, or its variant for smaller Macs),
    /// preferring families Kapitsa describes for coding or agents.
    static func recommended(_ families: [CatalogFamily]) -> CatalogVariant? {
        let candidates = families.flatMap { family in
            ([family.defaultVariant].compactMap { $0 } + family.variants.filter(\.forSmallerMacs))
                .filter(fits).map { (variant: $0, coding: codingOriented(family)) }
        }
        let pool = candidates.contains(where: \.coding) ? candidates.filter(\.coding) : candidates
        return pool.max { $0.variant.gigabytes < $1.variant.gigabytes }?.variant
    }
}

/// Searches Hugging Face for MLX models Kapitsa can run.
enum HuggingFace {
    struct Model: Identifiable, Decodable, Hashable {
        let id: String
        let downloads: Int?
        let likes: Int?
        let tags: [String]?

        var modelType: String? { tags?.first { ModelScanner.qwenTypes.contains($0) || ModelScanner.otherTypes.contains($0) } }
        /// Kapitsa downloads Qwen3.5-family MLX repositories by name.
        var likelyCompatible: Bool { modelType.map(ModelScanner.qwenTypes.contains) ?? false }
    }

    struct Details {
        let bytes: Int64
        let problem: String?
    }

    static func search(_ query: String) async throws -> [Model] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "filter", value: "mlx"),
                                 URLQueryItem(name: "sort", value: "downloads"), URLQueryItem(name: "direction", value: "-1"),
                                 URLQueryItem(name: "limit", value: "50")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Kapitsa.Failure(errorDescription: "Unable to reach Hugging Face. Check your internet connection.") }
        return try JSONDecoder().decode([Model].self, from: data)
    }

    /// Download size and whether the repository's config is one Kapitsa runs.
    static func details(_ id: String) async throws -> Details {
        let info = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!
        let (data, _) = try await URLSession.shared.data(from: info)
        let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let siblings = (object["siblings"] as? [[String: Any]]) ?? []
        let bytes = siblings.reduce(Int64(0)) { $0 + Int64(($1["size"] as? Int) ?? 0) }
        let configURL = URL(string: "https://huggingface.co/\(id)/resolve/main/config.json")!
        let (configData, response) = try await URLSession.shared.data(from: configURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            return Details(bytes: bytes, problem: "No config.json found. The repository may be gated (set HF_TOKEN) or not an MLX model.")
        }
        guard ModelScanner.family(config) == "qwen" else {
            return Details(bytes: bytes, problem: "Unsupported architecture: \(config["model_type"] as? String ?? "unknown"). Hugging Face downloads support Qwen3.5-family MLX models.")
        }
        return Details(bytes: bytes, problem: ModelScanner.quantizationError(config))
    }
}

/// Downloads run `kapitsa pull`; progress is measured from the size of the folder it fills.
@MainActor
final class Downloads: ObservableObject {
    enum State: Equatable { case preparing, running, pausing, paused, failed(String), finished }

    struct Job: Identifiable {
        let id: String
        var title: String
        var expected: Int64
        var folder: URL?
        var done: Int64 = 0
        var state = State.preparing
        var lastLine = ""
        var fraction: Double { expected > 0 ? min(0.99, Double(done) / Double(expected)) : 0 }
        /// Busy: a second start or a pause is meaningless until this state changes.
        var busy: Bool { [.preparing, .running, .pausing].contains(state) }
        var showsProgress: Bool { state != .finished }
    }

    static let shared = Downloads()
    @Published private(set) var jobs: [String: Job] = [:]
    var finished: (String) -> Void = { _ in }
    private var processes: [String: Process] = [:]

    /// A drafter to fetch after a model, from its own repository, moved into the model's folder (such as
    /// dflash2/) where Kapitsa finds it, the same layout as Kapitsa's catalog downloads.
    struct Companion: Equatable { let repo: String; let into: String }
    private var companions: [String: Companion] = [:]
    /// Set while the companion, not the model, is downloading.
    private var fetchingCompanion: Set<String> = []

    var active: [Job] { jobs.values.filter(\.busy).sorted { $0.title < $1.title } }

    /// Starts or resumes a download. Ignored while one for the same model is preparing, running or pausing.
    func start(_ spec: String, title: String, expectedBytes: Int64, companion: Companion? = nil) {
        guard processes[spec] == nil, jobs[spec]?.busy != true else { return }
        if let companion { companions[spec] = companion }
        if var job = jobs[spec] {
            // Resuming: keep the progress already on disk instead of dropping back to zero.
            job.state = .preparing
            job.expected = expectedBytes > 0 ? expectedBytes : job.expected
            jobs[spec] = job
        } else {
            jobs[spec] = Job(id: spec, title: title, expected: expectedBytes)
        }
        Task {
            do {
                let plan = try await Kapitsa.run(["pull", spec, "--dry-run", "--json"], timeout: 60)
                let json = plan.output.split(separator: "\n").last { $0.hasPrefix("{") }.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                guard plan.code == 0, let json else {
                    jobs[spec]?.state = .failed(plan.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "Model not found.")
                    return
                }
                if let dir = json["dir"] as? String { jobs[spec]?.folder = URL(fileURLWithPath: dir) }
                if json["downloaded"] as? Bool == true { modelDone(spec); return }
                // Paused while preparing: don't start the transfer.
                guard jobs[spec]?.state == .preparing else { jobs[spec]?.state = .paused; return }
                try run(spec)
            } catch {
                jobs[spec]?.state = .failed(error.localizedDescription)
            }
        }
    }

    private func run(_ spec: String, pulling repo: String? = nil, also measured: URL? = nil) throws {
        guard let binary = Kapitsa.binary else { throw Kapitsa.Failure(errorDescription: "Kapitsa engine not found. Reinstall Nearloop.") }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["pull", repo ?? spec]
        process.environment = Kapitsa.environment()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
                .map { Kapitsa.clean(String($0)) }
                .filter { !$0.isEmpty }
            guard let last = lines.last else { return }
            Task { @MainActor in self?.jobs[spec]?.lastLine = last }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.processes[spec] = nil
                let companion = self.fetchingCompanion.remove(spec) != nil
                if finished.terminationStatus == 0 { companion ? self.companionDone(spec) : self.modelDone(spec) }
                else if self.jobs[spec]?.state == .pausing || finished.terminationReason == .uncaughtSignal || finished.terminationStatus == 130 { self.jobs[spec]?.state = .paused }
                else { self.jobs[spec]?.state = .failed(self.jobs[spec]?.lastLine ?? "Download failed (code \(finished.terminationStatus)).") }
            }
        }
        try process.run()
        processes[spec] = process
        jobs[spec]?.state = .running
        Task { [weak self] in
            while let self, self.processes[spec] != nil {
                if let folder = self.jobs[spec]?.folder {
                    let size = await Task.detached { SystemMemory.allocatedBytes(folder) + (measured.map(SystemMemory.allocatedBytes) ?? 0) }.value
                    self.jobs[spec]?.done = size
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// The model is in place: fetch its companion if it has one that isn't there yet, else finish.
    private func modelDone(_ spec: String) {
        guard let companion = companions[spec], let folder = jobs[spec]?.folder,
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent(companion.into).appendingPathComponent("config.json").path) else {
            complete(spec); return
        }
        jobs[spec]?.state = .preparing
        jobs[spec]?.lastLine = "Downloading the drafter…"
        Task {
            do {
                let plan = try await Kapitsa.run(["pull", companion.repo, "--dry-run", "--json"], timeout: 60)
                let json = plan.output.split(separator: "\n").last { $0.hasPrefix("{") }.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                guard plan.code == 0, let dir = json?["dir"] as? String else {
                    jobs[spec]?.state = .failed("The drafter couldn’t be found: \(companion.repo).")
                    return
                }
                guard jobs[spec]?.state == .preparing else { jobs[spec]?.state = .paused; return }
                if json?["downloaded"] as? Bool == true { companionDone(spec); return }
                fetchingCompanion.insert(spec)
                try run(spec, pulling: companion.repo, also: URL(fileURLWithPath: dir))
            } catch {
                jobs[spec]?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Moves the downloaded companion into the model's folder, replacing any earlier copy.
    private func companionDone(_ spec: String) {
        guard let companion = companions[spec], let folder = jobs[spec]?.folder else { complete(spec); return }
        Task {
            let plan = try? await Kapitsa.run(["pull", companion.repo, "--dry-run", "--json"], timeout: 60)
            let json = plan?.output.split(separator: "\n").last { $0.hasPrefix("{") }.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            let target = folder.appendingPathComponent(companion.into)
            do {
                guard let dir = json?["dir"] as? String else { throw Kapitsa.Failure(errorDescription: "The drafter download wasn’t found.") }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: dir), to: target)
                complete(spec)
            } catch {
                jobs[spec]?.state = .failed("The drafter couldn’t be put in place: \(error.localizedDescription)")
            }
        }
    }

    private func complete(_ spec: String) {
        jobs[spec]?.state = .finished
        jobs[spec]?.done = jobs[spec]?.expected ?? 0
        finished(spec)
    }

    /// Pauses a download; it shows "Pausing…" until Kapitsa has stopped, then "Paused".
    func pause(_ spec: String) {
        guard let state = jobs[spec]?.state, state == .preparing || state == .running else { return }
        jobs[spec]?.state = .pausing
        processes[spec]?.interrupt()
    }

    func dismiss(_ spec: String) { if processes[spec] == nil { jobs[spec] = nil } }

    /// Deletes a model Kapitsa downloaded (`kapitsa rm`).
    func delete(_ spec: String) async throws {
        let result = try await Kapitsa.run(["rm", spec], timeout: 120)
        if result.code != 0 { throw Kapitsa.Failure(errorDescription: result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        jobs[spec] = nil
    }
}
