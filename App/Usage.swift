import Foundation

/// Tokens the local models read and wrote, by day, kept on this Mac only.
struct DayUsage: Codable, Equatable {
    var requests = 0
    var prompt = 0      // every prompt token, cached ones included
    var cached = 0
    var output = 0
    var models: [String: Int] = [:]
    var clients: [String: Int] = [:]
    var total: Int { prompt + output }
    /// Requests whose app the dashboard didn't name.
    static let unidentified = "Unidentified"

    private enum CodingKeys: String, CodingKey { case requests, prompt, cached, output, models, clients }

    init() {}

    /// Tolerates missing fields, so a file from an older or newer version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        prompt = try c.decodeIfPresent(Int.self, forKey: .prompt) ?? 0
        cached = try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        models = try c.decodeIfPresent([String: Int].self, forKey: .models) ?? [:]
        // Older builds called unidentified requests "Other".
        var clients = try c.decodeIfPresent([String: Int].self, forKey: .clients) ?? [:]
        if let other = clients.removeValue(forKey: "Other") { clients[Self.unidentified, default: 0] += other }
        self.clients = clients
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    /// Keyed "yyyy-MM-dd" in the user's time zone.
    @Published private(set) var days: [String: DayUsage] = [:]

    private static var url: URL { AppPaths.support.appendingPathComponent("usage.json") }

    static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    private init() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        if let saved = try? JSONDecoder().decode([String: DayUsage].self, from: data) {
            days = saved
        } else {
            // Unreadable: set it aside rather than overwrite the history with the next request.
            let backup = Self.url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.url, to: backup)
        }
    }

    /// Adds one finished request.
    func record(prompt: Int, cached: Int, output: Int, model: String, client: String, on date: Date = Date()) {
        let prompt = max(0, prompt), output = max(0, output), cached = min(max(0, cached), prompt)
        guard prompt + output > 0 else { return }
        let key = Self.dayFormat.string(from: date)
        var day = days[key] ?? DayUsage()
        day.requests += 1
        day.prompt += prompt
        day.cached += cached
        day.output += output
        let tokens = prompt + output
        if !model.isEmpty { day.models[model, default: 0] += tokens }
        day.clients[client.isEmpty || client == "—" ? DayUsage.unidentified : client, default: 0] += tokens
        days[key] = day
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: Self.url, options: .atomic) }
    }

    // MARK: Summaries

    var all: DayUsage {
        days.values.reduce(into: DayUsage()) { sum, day in
            sum.requests += day.requests; sum.prompt += day.prompt; sum.cached += day.cached; sum.output += day.output
            for (name, tokens) in day.models { sum.models[name, default: 0] += tokens }
            for (name, tokens) in day.clients { sum.clients[name, default: 0] += tokens }
        }
    }

    func usage(on date: Date) -> DayUsage? { days[Self.dayFormat.string(from: date)] }

    /// Consecutive days with use, ending today (or yesterday, so a streak survives until the day is over).
    var currentStreak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if (usage(on: day)?.total ?? 0) == 0 { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while let used = usage(on: day), used.total > 0 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    var longestStreak: Int {
        let dates = days.filter { $0.value.total > 0 }.keys.compactMap { Self.dayFormat.date(from: $0) }.sorted()
        var longest = 0, run = 0
        var previous: Date?
        for date in dates {
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: date).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    var busiestDay: (date: Date, usage: DayUsage)? {
        days.filter { $0.value.total > 0 }.max { $0.value.total < $1.value.total }.flatMap { key, usage in Self.dayFormat.date(from: key).map { ($0, usage) } }
    }
}

/// Well-known texts to measure token counts against. Word counts are the commonly cited figures, rounded;
/// English runs at about 1.3 tokens per word, so every comparison is an approximation.
enum TokenComparisons {
    static let tokensPerWord = 1.3
    static let works: [(name: String, words: Double)] = [
        ("The Great Gatsby", 47_000),
        ("Moby-Dick", 206_000),
        ("The Lord of the Rings", 480_000),
        ("War and Peace", 587_000),
        ("the King James Bible", 783_000),
        ("the complete works of Shakespeare", 884_000),
        ("all seven Harry Potter books", 1_084_000),
        ("the whole English Wikipedia", 4_500_000_000),
    ]

    static func tokens(_ words: Double) -> Double { words * tokensPerWord }

    /// The work the headline uses: the largest one the total covers at least once, else the smallest.
    private static func headlineWork(_ total: Double) -> (name: String, words: Double) {
        works.last { total >= tokens($0.words) } ?? works[0]
    }

    /// "about 8.8× all seven Harry Potter books".
    static func headline(_ total: Int) -> String {
        let total = Double(total), work = headlineWork(total)
        if total < tokens(work.words) {
            return "about " + percent(total / tokens(work.words)) + " of " + work.name
        }
        return "about " + times(total / tokens(work.words)) + " " + work.name
    }

    /// The same total against a few other works, for the list under the headline.
    static func others(_ total: Int) -> [String] {
        let total = Double(total), shown = headlineWork(total).name
        return works.filter { $0.name != shown && total >= tokens($0.words) * 0.05 && total < tokens($0.words) * 5_000 }
            .suffix(4).reversed().map { work in
                let ratio = total / tokens(work.words)
                return ratio >= 1 ? times(ratio) + " " + work.name : percent(ratio) + " of " + work.name
            }
    }

    /// 1% to 99%: a share just under a whole one reads as 99%, not 100%.
    private static func percent(_ ratio: Double) -> String {
        "\(min(99, max(1, Int((ratio * 100).rounded()))))%"
    }

    private static func times(_ ratio: Double) -> String {
        ratio >= 100 ? "\(Int(ratio.rounded()).formatted())×" : ratio >= 10 ? String(format: "%.0f×", ratio) : String(format: "%.1f×", ratio)
    }
}

/// What the same tokens would cost on a cloud API, at Anthropic's list prices (October 2026, per million
/// tokens). Other tokenizers count text a little differently, so this is an estimate.
enum CloudPrices {
    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let input: Double
        let cachedInput: Double
        let output: Double
    }

    static let models = [
        Model(id: "sonnet", name: "Claude Sonnet 5.5", input: 2, cachedInput: 0.20, output: 10),
        Model(id: "opus", name: "Claude Opus 5.5", input: 4, cachedInput: 0.20, output: 20),
    ]

    static func cost(_ usage: DayUsage, _ model: Model) -> Double {
        let uncached = Double(max(0, usage.prompt - usage.cached))
        return (uncached * model.input + Double(usage.cached) * model.cachedInput + Double(usage.output) * model.output) / 1_000_000
    }
}

/// "845K", "12.4M", "1.2B".
func compactTokens(_ count: Int) -> String {
    let value = Double(max(0, count))
    // Each unit is chosen after rounding, so 999,999 reads 1M rather than 1000K.
    if value < 1_000 { return "\(Int(value))" }
    if (value / 1_000).rounded() < 1_000 { return String(format: "%.0fK", value / 1_000) }
    if (value / 1_000_000 * 10).rounded() / 10 < 1_000 {
        return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
    if (value / 1_000_000_000 * 10).rounded() / 10 < 1_000 {
        return String(format: "%.1fB", value / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
    }
    return String(format: "%.1fT", value / 1_000_000_000_000).replacingOccurrences(of: ".0T", with: "T")
}

/// "1 day", "3 days".
func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

/// How dark a day is drawn in the activity grid.
enum Heatmap {
    /// 0 for no use, else 1–4 by rank among the days with use in view (sorted), like GitHub's quartiles: a few
    /// heavy days don't wash out the rest, the busiest day is always the darkest, and equal days look alike.
    static func level(_ total: Int, among used: [Int]) -> Int {
        guard total > 0, !used.isEmpty else { return 0 }
        guard used.count > 1 else { return 4 }
        // Days at or below this one, as a share of the others: 0 for the quietest, 1 for the busiest.
        var low = 0, high = used.count
        while low < high { let mid = (low + high) / 2; if used[mid] <= total { low = mid + 1 } else { high = mid } }
        let rank = Double(low - 1) / Double(used.count - 1)
        return 1 + min(3, Int(rank * 3.999))
    }
}
