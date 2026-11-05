// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// The decision model, its calibration and the recurring expenses, built from local data
/// (docs/design/fijos-y-categoria-automatica.md). Cheap enough to rebuild per screen.
struct Brain {
    let model: CategoryModel
    let calibration: Calibration
    let recurring: [Recurring]
    let categories: [CategoryItem]
    let stats: (auto: Int, corrected: Int, precision: Double?)

    func category(_ id: String?) -> CategoryItem? { categories.first { $0.id == id } }

    /// Categories ranked by the model for a payment, and the one to highlight (suggest or act band).
    func ranking(for m: Movement) -> (best: CategoryItem?, ranked: [CategoryItem]) {
        let d = model.decide(calibration, DecisionState(m.dto))
        let ranked = d.ranked.compactMap { r in categories.first { $0.id == r.id } }
        let rest = categories.filter { c in !ranked.contains { $0.id == c.id } }.sorted { $0.displayName < $1.displayName }
        return (d.band == .ask ? nil : category(d.categoryId), ranked + rest)
    }
}

enum Smart {
    static func brain(movements: [Movement], categories: [CategoryItem], now: Date = Date()) -> Brain {
        let txs = movements.map(\.dto)
        let live = categories.filter { !$0.deleted }
        let active = Set(live.map(\.id))
        return Brain(model: CategoryModel.train(txs, active: active),
                     calibration: CategoryModel.calibrate(txs, active: active),
                     recurring: Insights.recurring(txs, now: now),
                     categories: live,
                     stats: CategoryModel.liveStats(txs))
    }

    @MainActor
    static func brain(_ context: ModelContext) -> Brain {
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.deleted == false }))) ?? []
        let categories = (try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.deleted == false }))) ?? []
        return brain(movements: movements, categories: categories)
    }
}

// MARK: - Recurring expenses

struct FixedRow: View {
    let item: Recurring
    let category: CategoryItem?

    private var when: String {
        let date = ISODate.date(item.next) ?? Date()
        let short = date.formatted(.dateTime.day().month(.abbreviated))
        switch item.status {
        case .missed: return String(localized: "fixed.missed \(short)")
        default:
            if item.daysToNext <= 0 { return L("fixed.today") }
            if item.daysToNext == 1 { return L("fixed.tomorrow") }
            if item.daysToNext <= 7 { return String(localized: "fixed.inDays \(item.daysToNext)") }
            return String(localized: "fixed.on \(short)")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Tile(look: Looks.of(category))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.merchant).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: when)
                        .foregroundStyle(item.status == .missed ? Theme.warn : item.status == .soon ? Color(hex: 0xFF4F6D) : Color.secondary)
                        .fontWeight(item.status == .scheduled ? .regular : .bold)
                    Text(verbatim: "· " + L("fixed." + item.cadence.rawValue) + (item.sure ? "" : " · " + L("fixed.likely")))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: Formatting.money(item.amount, item.currency)).font(.body.weight(.bold)).monospacedDigit()
                if let change = item.priceChange {
                    Text("fixed.priceUp \(Formatting.money(change.from, item.currency))")
                        .font(.caption2.weight(.bold)).foregroundStyle(Theme.warn)
                }
            }
        }
    }
}

/// Summary card: fixed charges per month in the hero currency and the next ones due.
struct FixedCard: View {
    let brain: Brain
    let currency: String

    var body: some View {
        let items = brain.recurring.filter { $0.currency == currency }
        if !items.isEmpty {
            let monthly = items.reduce(Int64(0)) { $0 + $1.monthly }
            let upcoming = items.filter { $0.status != .scheduled }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("fixed.title").font(.headline)
                    Spacer()
                    NavigationLink("month.seeAll") { FixedView() }.font(.subheadline.weight(.semibold))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: Formatting.money(monthly, currency)).font(.title2.weight(.heavy)).monospacedDigit()
                    Text("fixed.perMonth \(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array((upcoming.isEmpty ? items : upcoming).prefix(4))) { r in
                    FixedRow(item: r, category: brain.category(r.categoryId))
                }
            }
            .card()
        }
    }
}

struct FixedView: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]

    var body: some View {
        let brain = Smart.brain(movements: movements, categories: categories)
        let items = brain.recurring
        let totals = Dictionary(grouping: items, by: \.currency).mapValues { $0.reduce(Int64(0)) { $0 + $1.monthly } }
        let attention = items.filter { $0.status == .missed || $0.priceChange != nil }
        let upcoming = items.filter { $0.status != .missed && $0.priceChange == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if items.isEmpty {
                    EmptyState(emoji: "🔁", title: "fixed.emptyTitle", text: "fixed.empty").card()
                } else {
                    ForEach(totals.keys.sorted(), id: \.self) { cur in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("fixed.monthlyTotal \(cur)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(verbatim: Formatting.money(totals[cur] ?? 0, cur)).font(.largeTitle.weight(.heavy)).monospacedDigit()
                            Text("fixed.yearlyTotal \(Formatting.money((totals[cur] ?? 0) * 12, cur))")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .card()
                    }
                    if !attention.isEmpty { section("fixed.attention", attention, brain) }
                    if !upcoming.isEmpty { section("fixed.upcoming", upcoming, brain) }
                    Text("fixed.how").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("fixed.title")
    }

    private func section(_ title: LocalizedStringKey, _ list: [Recurring], _ brain: Brain) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(list) { r in FixedRow(item: r, category: brain.category(r.categoryId)) }
        }
        .card()
    }
}

// MARK: - Automatic category settings

struct AutoCategorySection: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @AppStorage("autoCategory") private var enabled = true

    private func pct(_ x: Double?) -> String { x.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? L("auto.na") }

    var body: some View {
        let brain = Smart.brain(movements: movements, categories: categories)
        let cal = brain.calibration
        Section {
            Toggle(isOn: $enabled) {
                Label("auto.toggle", systemImage: "sparkles")
            }
            LabeledContent("auto.history") {
                Text(verbatim: cal.cases > 0 ? String(localized: "auto.historyValue \(pct(cal.accuracy)) \(cal.cases)") : L("auto.learning"))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("auto.threshold") {
                Text(verbatim: cal.threshold == nil ? L("auto.notYet") : String(localized: "auto.thresholdValue \(pct(cal.threshold)) \(pct(cal.coverage))"))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("auto.live") {
                Text(verbatim: brain.stats.auto + brain.stats.corrected > 0
                     ? String(localized: "auto.liveValue \(brain.stats.auto) \(brain.stats.corrected) \(pct(brain.stats.precision))")
                     : L("auto.noneYet"))
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("auto.title")
        } footer: {
            Text("auto.intro")
        }
    }
}
