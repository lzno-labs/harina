// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]

    var body: some View {
        TabView {
            NavigationStack { MonthView() }
                .tabItem { Label("tab.month", systemImage: "chart.pie") }
            NavigationStack { MovementForm(movement: nil) }
                .tabItem { Label("tab.add", systemImage: "plus.circle") }
            NavigationStack { ReviewView() }
                .tabItem { Label("tab.review", systemImage: "tray") }
                .badge(movements.filter(\.isPendingReview).count)
            NavigationStack { SettingsView() }
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
        }
    }
}

struct LockedView: View {
    let unlock: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Button("lock.unlock", action: unlock).buttonStyle(.borderedProminent)
        }
    }
}

struct MonthView: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt, order: .reverse)
    private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @EnvironmentObject private var sync: SyncService
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!

    private var inMonth: [Movement] { movements.filter { month.contains($0.occurredAt) } }

    struct Total: Identifiable {
        var id: String { currency }
        let currency: String
        let amount: Int64
    }

    private func total(_ kind: String) -> [Total] {
        Dictionary(grouping: inMonth.filter { $0.kind == kind }, by: \.currency)
            .map { Total(currency: $0.key, amount: $0.value.reduce(0) { $0 + $1.amountMinor }) }
            .sorted { $0.currency < $1.currency }
    }

    struct CategoryLine: Identifiable {
        let id: String
        let currency: String
        let name: String
        let total: Int64
    }

    private var byCategory: [CategoryLine] {
        Dictionary(grouping: inMonth.filter { $0.kind == "expense" }) { "\($0.currency)|\($0.categoryId ?? "")" }
            .map { key, list in
                let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return CategoryLine(id: key, currency: parts[0], name: name(parts[1]), total: list.reduce(0) { $0 + $1.amountMinor })
            }
            .sorted { $0.total > $1.total }
    }

    private func name(_ id: String?) -> String {
        categories.first { $0.id == id }?.displayName ?? String(localized: "category.none")
    }

    private func shift(_ months: Int) {
        let d = Calendar.current.date(byAdding: .month, value: months, to: month.start)!
        month = Calendar.current.dateInterval(of: .month, for: d)!
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("month.previous")
                    Spacer()
                    Text(Formatting.month(month.start)).font(.headline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("month.next")
                }
                .buttonStyle(.borderless)
                ForEach(total("expense")) { t in
                    LabeledContent("month.spent \(t.currency)") { Text(Formatting.money(t.amount, t.currency)).foregroundStyle(.red) }
                }
                ForEach(total("income")) { t in
                    LabeledContent("month.earned \(t.currency)") { Text(Formatting.money(t.amount, t.currency)).foregroundStyle(.green) }
                }
                if inMonth.isEmpty { Text("month.empty").foregroundStyle(.secondary) }
            }
            if !byCategory.isEmpty {
                Section("month.byCategory") {
                    ForEach(byCategory) { line in
                        LabeledContent(line.name) { Text(Formatting.money(line.total, line.currency)) }
                    }
                }
            }
            if !inMonth.isEmpty {
                Section("month.movements") {
                    ForEach(inMonth) { m in
                        NavigationLink { MovementForm(movement: m) } label: { MovementRow(movement: m, category: name(m.categoryId)) }
                    }
                }
            }
        }
        .navigationTitle("month.title")
        .refreshable { await sync.sync() }
    }
}

struct MovementRow: View {
    let movement: Movement
    let category: String
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(movement.merchant ?? movement.note ?? category)
                Text("\(Formatting.day(movement.occurredAt)) · \(category)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if movement.needsReview, let raw = movement.rawAmount {
                Text(raw).foregroundStyle(.orange)
            } else {
                Text(Formatting.money(movement.amountMinor, movement.currency))
                    .foregroundStyle(movement.kind == "income" ? Color.green : Color.primary)
            }
            if movement.dirty { Image(systemName: "icloud.slash").foregroundStyle(.secondary).accessibilityLabel("sync.pending") }
        }
    }
}

struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt, order: .reverse)
    private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @EnvironmentObject private var sync: SyncService

    var body: some View {
        let pending = movements.filter(\.isPendingReview)
        List {
            if pending.isEmpty { Text("review.empty").foregroundStyle(.secondary) }
            ForEach(pending) { m in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink { MovementForm(movement: m) } label: { MovementRow(movement: m, category: String(localized: "category.none")) }
                    if !m.needsReview, let s = Suggestion.category(for: m.merchant, in: movements, categories: categories) {
                        Button("review.apply \(s.displayName)") {
                            m.categoryId = s.id
                            m.touch()
                            try? context.save()
                            Task { await sync.sync() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("review.title")
    }
}

enum Suggestion {
    /// The category last used for this merchant.
    static func category(for merchant: String?, in movements: [Movement], categories: [CategoryItem]) -> CategoryItem? {
        let key = MerchantKey.normalize(merchant)
        guard !key.isEmpty else { return nil }
        let last = movements
            .filter { $0.categoryId != nil && MerchantKey.normalize($0.merchant) == key }
            .max { $0.updatedAt < $1.updatedAt }
        return categories.first { $0.id == last?.categoryId }
    }
}
