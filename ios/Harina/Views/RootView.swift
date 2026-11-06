// SPDX-License-Identifier: MPL-2.0
import Charts
import HarinaKit
import SwiftData
import SwiftUI

struct RootView: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @State private var tab = 0
    @State private var celebrate: Movement?
    @AppStorage("firstCaptureSeen") private var firstCaptureSeen = false
    /// Set by a notification ("Otra…" or a tap) to open "Por revisar".
    @AppStorage("openTab") private var openTab = -1

    private var applePayCount: Int { movements.filter { $0.source == "apple_pay" }.count }

    /// The first automatic payment gets its moment (once).
    private func checkFirstCapture() {
        guard !firstCaptureSeen, let first = movements.filter({ $0.source == "apple_pay" }).min(by: { $0.occurredAt < $1.occurredAt }) else { return }
        firstCaptureSeen = true
        celebrate = first
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { MonthView(tab: $tab) }
                .tabItem { Label("tab.month", systemImage: "house.fill") }
                .tag(0)
            NavigationStack { MovementsView() }
                .tabItem { Label("tab.movements", systemImage: "list.bullet") }
                .tag(1)
            NavigationStack { MovementForm(movement: nil) }
                .tabItem { Label("tab.add", systemImage: "plus.circle.fill") }
                .tag(2)
            NavigationStack { ReviewView() }
                .tabItem { Label("tab.review", systemImage: "tray.fill") }
                .badge(movements.filter(\.isPendingReview).count)
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("tab.settings", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .tint(Color(hex: 0xFF4F6D))
        .onAppear {
            checkFirstCapture()
            if openTab >= 0 { tab = openTab; openTab = -1 }
        }
        .onChange(of: openTab) { _, new in
            if new >= 0 { tab = new; openTab = -1 }
        }
        .onChange(of: applePayCount) { _, _ in checkFirstCapture() }
        .sheet(item: $celebrate) { FirstCaptureView(movement: $0).environmentObject(SyncService.shared) }
    }
}

struct LockedView: View {
    let unlock: () -> Void
    var body: some View {
        ZStack {
            Theme.brand.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                Button(action: unlock) {
                    Label("lock.unlock", systemImage: "faceid").font(.headline).padding(.horizontal, 22).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: 0x1A1030))
                .background(.white, in: Capsule())
            }
        }
    }
}

// MARK: - Summary

struct MonthView: View {
    @Binding var tab: Int
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt, order: .reverse)
    private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @EnvironmentObject private var sync: SyncService
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!
    @State private var currency: String?

    private var inMonth: [Movement] { movements.filter { month.contains($0.occurredAt) } }
    private var currencies: [String] {
        let used = Set(movements.map(\.currency))
        return ["CRC", "USD"].filter(used.contains) + used.subtracting(["CRC", "USD"]).sorted()
    }
    private var cur: String {
        if let currency { return currency }
        let counts = Dictionary(grouping: inMonth.filter { $0.kind == "expense" }, by: \.currency).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? currencies.first ?? AppSettings.defaultCurrency
    }

    private func total(_ kind: String, in list: [Movement]) -> Int64 {
        list.filter { $0.kind == kind && $0.currency == cur }.reduce(0) { $0 + $1.amountMinor }
    }

    private func category(_ id: String?) -> CategoryItem? { categories.first { $0.id == id } }

    private func shift(_ months: Int) {
        let d = Calendar.current.date(byAdding: .month, value: months, to: month.start)!
        withAnimation(.snappy) { month = Calendar.current.dateInterval(of: .month, for: d)! }
    }

    var body: some View {
        let spent = total("expense", in: inMonth)
        let earned = total("income", in: inMonth)
        let pending = movements.filter(\.isPendingReview).count
        let brain = Smart.brain(movements: movements, categories: categories)
        let projection = month.contains(Date())
            ? Insights.projectMonth(movements.map(\.dto), recurring: brain.recurring, currency: cur) : nil
        ScrollView {
            VStack(spacing: 16) {
                header
                FirstWeekCard()
                hero(spent: spent, earned: earned, projection: projection)
                if pending > 0 { reviewBanner(pending) }
                PaceCard(month: month, currency: cur, movements: movements)
                FixedCard(brain: brain, currency: cur)
                categoriesCard(spent: spent)
                recentCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await sync.sync() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Greeting.key).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text("month.title").font(.largeTitle.weight(.heavy)).tracking(-0.8)
            }
            Spacer()
            HStack(spacing: 2) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .accessibilityLabel("month.previous")
                Text(Formatting.shortMonth(month.start)).font(.subheadline.weight(.bold)).frame(minWidth: 70)
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .accessibilityLabel("month.next")
            }
            .buttonStyle(.plain)
            .padding(4)
            .background(Theme.card, in: Capsule())
        }
        .padding(.top, 8)
    }

    private func hero(spent: Int64, earned: Int64, projection: MonthProjection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("month.spentIn \(Formatting.monthName(month.start))").font(.subheadline.weight(.semibold)).opacity(0.9)
                Spacer()
                if currencies.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(currencies, id: \.self) { c in
                            Button { withAnimation(.snappy) { currency = c } } label: {
                                Text(verbatim: c).font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 5)
                                    .foregroundStyle(c == cur ? Color(hex: 0x1A1030) : .white)
                                    .background(c == cur ? Color.white : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(.black.opacity(0.16), in: Capsule())
                }
            }
            Text(Formatting.money(spent, cur))
                .font(.system(size: 46, weight: .heavy, design: .default))
                .monospacedDigit()
                .tracking(-1.5)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            ComparisonPill(month: month, currency: cur, spent: spent, movements: movements)
            if let projection {
                Text("month.projection \(Formatting.money(projection.projected, cur))")
                    .font(.footnote.weight(.semibold)).opacity(0.92)
            }
            HStack(spacing: 10) {
                heroStat("month.income", Formatting.money(earned, cur))
                heroStat("month.balance", Formatting.money(earned - spent, cur))
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.brand
                Circle().fill(.white.opacity(0.22)).blur(radius: 50).frame(width: 260).offset(x: 140, y: -120)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color(hex: 0xFF4F6D).opacity(0.3), radius: 24, y: 12)
    }

    private func heroStat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).opacity(0.85)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reviewBanner(_ count: Int) -> some View {
        Button { tab = 3 } label: {
            HStack(spacing: 14) {
                IconTile(systemName: "tray.fill", colors: [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)], size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("month.reviewTitle \(count)").font(.headline)
                    Text("month.reviewSub").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private func categoriesCard(spent: Int64) -> some View {
        let groups = Dictionary(grouping: inMonth.filter { $0.kind == "expense" && $0.currency == cur }) { $0.categoryId ?? "" }
            .map { CategoryTotal(id: $0.key, total: $0.value.reduce(Int64(0)) { $0 + $1.amountMinor }) }
            .sorted { $0.total > $1.total }
        return VStack(alignment: .leading, spacing: 14) {
            Text("month.byCategory").font(.headline)
            if groups.isEmpty {
                EmptyState(emoji: "🌾", title: "month.emptyTitle", text: "month.empty")
            } else {
                HStack(spacing: 18) {
                    Chart(groups) { g in
                        SectorMark(angle: .value("chart.amount", g.total), innerRadius: .ratio(0.7), angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(Looks.of(category(g.id)).from)
                    }
                    .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("month.spentIn \(Formatting.monthName(month.start))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(Formatting.money(spent, cur)).font(.title3.weight(.heavy)).monospacedDigit().minimumScaleFactor(0.6)
                    }
                }
                ForEach(groups) { g in
                    let c = category(g.id)
                    let look = Looks.of(c)
                    HStack(spacing: 12) {
                        Tile(look: look, size: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(c?.displayName ?? String(localized: "category.none")).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(Formatting.money(g.total, cur)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.fill)
                                    Capsule().fill(look.gradient)
                                        .frame(width: max(4, geo.size.width * CGFloat(g.total) / CGFloat(max(spent, 1))))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .card()
    }

    @ViewBuilder private var recentCard: some View {
        let recent = Array(inMonth.prefix(8))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("month.recent").font(.headline)
                    Spacer()
                    Button("month.seeAll") { tab = 1 }.font(.subheadline.weight(.semibold))
                }
                DayGroups(movements: recent, categories: categories)
            }
            .card()
        }
    }
}

struct CategoryTotal: Identifiable {
    let id: String
    let total: Int64
}

enum Greeting {
    static var key: LocalizedStringKey {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "greeting.morning" : h < 19 ? "greeting.afternoon" : "greeting.evening"
    }
}

/// "12 % less than October at this point": spending so far against the same day last month.
struct ComparisonPill: View {
    let month: DateInterval
    let currency: String
    let spent: Int64
    let movements: [Movement]

    var body: some View {
        let cal = Calendar.current
        let prevStart = cal.date(byAdding: .month, value: -1, to: month.start)!
        let isThis = month.contains(Date())
        let day = cal.component(.day, from: Date())
        let prev = movements.filter {
            $0.kind == "expense" && $0.currency == currency && $0.occurredAt >= prevStart && $0.occurredAt < month.start
                && (!isThis || cal.component(.day, from: $0.occurredAt) <= day)
        }.reduce(Int64(0)) { $0 + $1.amountMinor }
        let name = Formatting.monthName(prevStart)
        HStack(spacing: 5) {
            if prev == 0 {
                Image(systemName: "sparkles")
                Text("month.vsNone")
            } else {
                let diff = Double(spent - prev) / Double(prev)
                let pct = abs(diff).formatted(.percent.precision(.fractionLength(0)))
                Image(systemName: diff < 0 ? Symbol.down : Symbol.up)
                if diff < 0 { Text("month.vsLess \(pct) \(name)") } else { Text("month.vsMore \(pct) \(name)") }
            }
        }
        .font(.caption.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.2), in: Capsule())
    }
}

/// Cumulative spending this month against last month.
struct PaceCard: View {
    let month: DateInterval
    let currency: String
    let movements: [Movement]

    struct Point: Identifiable {
        let id: String
        let day: Int
        let value: Double
        let series: String
    }

    private func cumulative(_ interval: DateInterval, upTo limit: Int?) -> [Point] {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: interval.start)?.count ?? 30
        var perDay = Array(repeating: Int64(0), count: days + 1)
        for m in movements where m.kind == "expense" && m.currency == currency && interval.contains(m.occurredAt) {
            perDay[cal.component(.day, from: m.occurredAt)] += m.amountMinor
        }
        var acc: Int64 = 0
        let series = interval == month ? "cur" : "prev"
        return (1...min(days, limit ?? days)).map { d in
            acc += perDay[d]
            return Point(id: "\(series)-\(d)", day: d, value: Double(acc), series: series)
        }
    }

    var body: some View {
        let prevStart = Calendar.current.date(byAdding: .month, value: -1, to: month.start)!
        let prev = Calendar.current.dateInterval(of: .month, for: prevStart)!
        let today = month.contains(Date()) ? Calendar.current.component(.day, from: Date()) : nil
        let cur = cumulative(month, upTo: today)
        let last = cumulative(prev, upTo: nil)
        VStack(alignment: .leading, spacing: 12) {
            Text("month.pace").font(.headline)
            Chart {
                ForEach(last) { p in
                    LineMark(x: .value("chart.day", p.day), y: .value("chart.amount", p.value), series: .value("chart.series", p.series))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 5]))
                        .interpolationMethod(.monotone)
                }
                ForEach(cur) { p in
                    AreaMark(x: .value("chart.day", p.day), y: .value("chart.amount", p.value))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFF4F6D).opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("chart.day", p.day), y: .value("chart.amount", p.value), series: .value("chart.series", p.series))
                        .foregroundStyle(Theme.brandHorizontal)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let lastPoint = cur.last {
                    PointMark(x: .value("chart.day", lastPoint.day), y: .value("chart.amount", lastPoint.value))
                        .symbolSize(90)
                        .foregroundStyle(Color(hex: 0xFF4F6D))
                }
            }
            .chartYAxis(.hidden)
            .chartXScale(domain: 1...31)
            .chartXAxis { AxisMarks(values: [1, 15, 31]) }
            .frame(height: 150)
            HStack(spacing: 16) {
                Label { Text("month.thisMonth") } icon: { Capsule().fill(Theme.brandHorizontal).frame(width: 14, height: 3) }
                Label { Text("month.lastMonth") } icon: { Capsule().fill(Color.secondary).frame(width: 14, height: 3) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .card()
    }
}

struct EmptyState: View {
    let emoji: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: emoji).font(.system(size: 44))
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Movements

struct MovementRow: View {
    let movement: Movement
    let category: CategoryItem?

    var body: some View {
        HStack(spacing: 12) {
            Tile(look: movement.kind == "income" && category == nil ? Looks.income : Looks.of(category))
            VStack(alignment: .leading, spacing: 2) {
                Text(movement.merchant ?? movement.note ?? category?.displayName ?? String(localized: "category.none"))
                    .font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if movement.source == "apple_pay" { Image(systemName: "bolt.fill").foregroundStyle(Theme.warn).font(.caption2) }
                    if movement.categoryAuto == 1 {
                        Image(systemName: "sparkles").foregroundStyle(Color(hex: 0xFF4F6D)).font(.caption2).accessibilityLabel("auto.mark")
                    }
                    Text(category?.displayName ?? String(localized: "category.none")).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if movement.needsReview && movement.amountMinor == 0, let raw = movement.rawAmount {
                    Text("review.fixAmount").font(.caption2.weight(.bold)).foregroundStyle(Theme.warn)
                    Text(verbatim: raw).font(.body.weight(.bold))
                } else {
                    Text((movement.kind == "income" ? "+" : "") + Formatting.money(movement.amountMinor, movement.currency))
                        .font(.body.weight(.bold)).monospacedDigit()
                        .foregroundStyle(movement.kind == "income" ? Theme.earn : Color.primary)
                }
                if movement.dirty {
                    Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("sync.pending")
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct DayGroup: Identifiable {
    let day: Date
    let list: [Movement]
    var id: Date { day }
}

/// Movements grouped by day, with the day's spending.
struct DayGroups: View {
    let movements: [Movement]
    let categories: [CategoryItem]

    var body: some View {
        let days = Dictionary(grouping: movements) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .map { DayGroup(day: $0.key, list: $0.value) }
            .sorted { $0.day > $1.day }
        ForEach(days) { group in
            let day = group.day
            let list = group.list
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Formatting.dayHeader(day)).textCase(.uppercase)
                    Spacer()
                    Text(Formatting.dayTotals(list)).monospacedDigit()
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                ForEach(list.sorted { $0.occurredAt > $1.occurredAt }) { m in
                    NavigationLink { MovementForm(movement: m) } label: {
                        MovementRow(movement: m, category: categories.first { $0.id == m.categoryId })
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

struct MovementsView: View {
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt, order: .reverse)
    private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @State private var query = ""
    @State private var filter = "all"
    static let filters = ["all", "expense", "income", "apple_pay"]

    private var filtered: [Movement] {
        let q = MerchantKey.normalize(query)
        return movements.filter { m in
            (filter == "all" || m.kind == filter || m.source == filter)
                && (q.isEmpty || MerchantKey.normalize("\(m.merchant ?? "") \(m.note ?? "") \(categories.first { $0.id == m.categoryId }?.displayName ?? "")").contains(q))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.filters, id: \.self) { f in
                            Button { withAnimation(.snappy) { filter = f } } label: { Text(L("movements.filter." + f)) }
                                .buttonStyle(ChipStyle(selected: filter == f))
                        }
                    }
                }
                if filtered.isEmpty {
                    EmptyState(emoji: "🔎", title: "movements.title", text: "movements.empty").card()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        DayGroups(movements: Array(filtered.prefix(300)), categories: categories)
                    }
                    .card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("movements.title")
        .searchable(text: $query, prompt: Text("movements.search"))
    }
}

// MARK: - Review

struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt, order: .reverse)
    private var movements: [Movement]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @EnvironmentObject private var sync: SyncService

    var body: some View {
        let pending = movements.filter(\.isPendingReview)
        let sorted = categories.sorted { $0.displayName < $1.displayName }
        let brain = Smart.brain(movements: movements, categories: categories)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if pending.isEmpty {
                    EmptyState(emoji: "🎉", title: "review.emptyTitle", text: "review.empty").card()
                } else {
                    Text("review.intro").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(pending) { m in
                        // The decision model ranks the categories; the best one is highlighted when it is likely.
                        let ranking = m.needsReview ? (best: CategoryItem?.none, ranked: sorted) : brain.ranking(for: m)
                        let suggestion = ranking.best
                        VStack(alignment: .leading, spacing: 12) {
                            NavigationLink { MovementForm(movement: m) } label: {
                                MovementRow(movement: m, category: nil)
                            }
                            .buttonStyle(.plain)
                            if m.needsReview {
                                NavigationLink { MovementForm(movement: m) } label: {
                                    Label("review.fixAmount", systemImage: "pencil").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(ChipStyle())
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(ranking.ranked) { c in
                                            Button { assign(c, to: m) } label: {
                                                HStack(spacing: 5) {
                                                    if c.id == suggestion?.id { Image(systemName: "sparkles") } else { Text(verbatim: Looks.of(c).glyph) }
                                                    Text(c.displayName)
                                                }
                                            }
                                            .buttonStyle(ChipStyle(highlighted: c.id == suggestion?.id))
                                        }
                                    }
                                }
                            }
                        }
                        .card()
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("review.title")
        .sensoryFeedback(.success, trigger: pending.count)
    }

    private func assign(_ c: CategoryItem, to m: Movement) {
        withAnimation(.snappy) {
            m.setCategory(byPerson: c.id)
            m.touch()
            try? context.save()
        }
        Task { await sync.sync() }
    }
}
