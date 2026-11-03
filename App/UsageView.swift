import SwiftUI

struct UsageView: View {
    @ObservedObject var usage = UsageStore.shared
    @AppStorage("costModel") private var costModel = "sonnet"

    var body: some View {
        let all = usage.all
        PageScaffold(title: "Usage", subtitle: "Every token your local models read and wrote. Counted on this Mac and never sent anywhere.") {
            if all.requests == 0 {
                ContentUnavailableView("No Usage Yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Load a model and use it from an agent, a task or the chat. Every request is counted here from now on."))
                    .frame(maxWidth: .infinity).padding(.vertical, 40).card()
            } else {
                tiles(all)
                ActivityGrid(usage: usage)
                HStack(alignment: .top, spacing: 14) {
                    comparisonCard(all).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
                    costCard(all).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
                }.fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    Breakdown(title: "By Model", symbol: "cpu", items: all.models).frame(maxWidth: .infinity, alignment: .topLeading).card()
                    Breakdown(title: "By App or Agent", symbol: "terminal", items: all.clients).frame(maxWidth: .infinity, alignment: .topLeading).card()
                }
            }
        }
    }

    private func tiles(_ all: DayUsage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            UsageTile(label: "Tokens", value: compactTokens(all.total),
                 detail: "\(compactTokens(all.prompt)) read · \(compactTokens(all.output)) written")
            UsageTile(label: "Requests", value: all.requests.formatted(),
                 detail: "\(usage.days.values.filter { $0.total > 0 }.count) days active")
            UsageTile(label: "Prompt Cache", value: all.prompt > 0 ? String(format: "%.0f%%", Double(all.cached) / Double(all.prompt) * 100) : "—",
                 detail: "\(compactTokens(all.cached)) tokens reused")
            UsageTile(label: "Streak", value: "\(usage.currentStreak) days", detail: "longest \(usage.longestStreak) days")
            if let busiest = usage.busiestDay {
                UsageTile(label: "Busiest Day", value: compactTokens(busiest.usage.total),
                     detail: busiest.date.formatted(.dateTime.month(.abbreviated).day().year()))
            }
        }
    }

    private func comparisonCard(_ all: DayUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("That’s Like Reading", systemImage: "books.vertical").font(.headline)
            Text(TokenComparisons.headline(all.total)).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(TokenComparisons.others(all.total), id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            Text("Counting about 1.3 tokens per English word.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func costCard(_ all: DayUsage) -> some View {
        let model = CloudPrices.models.first { $0.id == costModel } ?? CloudPrices.models[0]
        let cost = CloudPrices.cost(all, model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("On a Cloud API", systemImage: "cloud").font(.headline)
                Spacer()
                Picker("Model", selection: $costModel) {
                    ForEach(CloudPrices.models) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
            }
            Text(cost >= 100 ? "$" + Int(cost.rounded()).formatted() : String(format: "$%.2f", cost))
                .font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text("is what these tokens would have cost on \(model.name). On your Mac they cost nothing beyond electricity.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(String(format: "Anthropic list prices, October 2026: $%.2f input, $%.2f cached input, $%.0f output per million tokens. Tokenizers differ, so this is an estimate.",
                        model.input, model.cachedInput, model.output))
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UsageTile: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 16)
    }
}

/// A year of daily use as a grid of weeks, like a GitHub contribution graph.
private struct ActivityGrid: View {
    @ObservedObject var usage: UsageStore
    /// The grid's width, measured, so the 53 weeks always fit the card.
    @State private var width: CGFloat = 800
    private let gap: CGFloat = 3, labelWidth: CGFloat = 26
    private var cell: CGFloat { max(6, min(16, (width - labelWidth - gap * 53) / 53)) }
    private let calendar = Calendar.current

    var body: some View {
        let weeks = self.weeks
        let thresholds = self.thresholds
        let year = weeks.joined().compactMap { $0 }.reduce(0) { $0 + (usage.usage(on: $1)?.total ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(compactTokens(year)) tokens in the last year").font(.headline)
                Spacer()
                legend
            }
            VStack(alignment: .leading, spacing: 6) {
                    monthLabels(weeks)
                    HStack(alignment: .top, spacing: gap) {
                        weekdayLabels
                        ForEach(weeks.indices, id: \.self) { index in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { row in
                                    if let date = weeks[index][row] {
                                        let day = usage.usage(on: date)
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .fill(color(level(day?.total ?? 0, thresholds)))
                                            .frame(width: cell, height: cell)
                                            .help(tooltip(date, day))
                                    } else {
                                        Color.clear.frame(width: cell, height: cell)
                                    }
                                }
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            })
        }.card()
    }

    /// 53 columns of 7 days, oldest first, ending with the current week; future days are nil.
    private var weeks: [[Date?]] {
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = calendar.date(byAdding: .weekOfYear, value: -52, to: thisWeek)!
        return (0..<53).map { week in
            (0..<7).map { day in
                let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start)!
                return date > today ? nil : date
            }
        }
    }

    /// Quartiles of the days with any use, so a few heavy days don't wash out the rest.
    private var thresholds: [Int] {
        let used = usage.days.values.map(\.total).filter { $0 > 0 }.sorted()
        guard !used.isEmpty else { return [1, 1, 1] }
        return [0.25, 0.5, 0.75].map { used[min(used.count - 1, Int(Double(used.count) * $0))] }
    }

    private func level(_ total: Int, _ thresholds: [Int]) -> Int {
        guard total > 0 else { return 0 }
        return 1 + thresholds.filter { total > $0 }.count
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : Color.green.opacity([0, 0.3, 0.5, 0.75, 1][level])
    }

    private func tooltip(_ date: Date, _ day: DayUsage?) -> String {
        let label = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        guard let day, day.total > 0 else { return "\(label): no use" }
        return "\(label): \(compactTokens(day.total)) tokens in \(day.requests) requests"
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").font(.caption2).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(color($0)).frame(width: 10, height: 10) }
            Text("More").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var weekdayLabels: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                let index = (calendar.firstWeekday - 1 + row) % 7
                Text(row % 2 == 1 ? calendar.shortWeekdaySymbols[index] : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: labelWidth, height: cell, alignment: .leading)
            }
        }
    }

    private func monthLabels(_ weeks: [[Date?]]) -> some View {
        HStack(spacing: gap) {
            Color.clear.frame(width: labelWidth, height: 10)
            ForEach(weeks.indices, id: \.self) { index in
                let first = weeks[index].compactMap { $0 }.first
                // A month's name sits over its first week; none in the last two columns, where it would be cut off.
                let starts = index < weeks.count - 2 && (first.map { calendar.component(.day, from: $0) <= 7 } ?? false)
                Text(starts ? first!.formatted(.dateTime.month(.abbreviated)) : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize().frame(width: cell, alignment: .leading)
            }
        }
    }
}

private struct Breakdown: View {
    let title: String
    let symbol: String
    let items: [String: Int]

    var body: some View {
        let sorted = items.sorted { $0.value > $1.value }.prefix(6)
        let top = max(1, sorted.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            if sorted.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(sorted), id: \.key) { name, tokens in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(compactTokens(tokens)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(4, proxy.size.width * CGFloat(tokens) / CGFloat(top)), height: 4)
                    }.frame(height: 4)
                }
            }
        }
    }
}
