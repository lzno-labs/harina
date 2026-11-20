// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

// Envelopes, savings pots and payment reminders (docs/design/budgets-reminders-savings.md).

private func saveAndSync(_ context: ModelContext) {
    try? context.save()
    Task {
        await SyncService.shared.sync()
        await Reminders.reschedule()
    }
}

/// A progress bar for envelopes and savings goals.
struct Meter: View {
    let ratio: Double
    var level: MoneyTools.Level = .ok

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(level == .over ? AnyShapeStyle(Theme.spend) : level == .warn ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(Theme.brandHorizontal))
                    .frame(width: geo.size.width * min(1, max(0, ratio)))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Summary cards

/// «Próximos pagos»: reminders due in the next 7 days (or late), with «Ya pagué».
struct RemindersCard: View {
    @Query(filter: #Predicate<ReminderItem> { $0.deleted == false }) private var all: [ReminderItem]
    @AppStorage("space") private var space = ""
    @State private var paying: ReminderItem?

    var body: some View {
        let due = all.inSpace(Spaces.valid(space))
            .map { ($0, MoneyTools.reminder($0.dto)) }
            .filter { $0.1.status != .paid && $0.1.days <= 7 }
            .sorted { $0.1.days < $1.1.days }
        if !due.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("reminders.upcoming").font(.headline)
                    Spacer()
                    NavigationLink("month.seeAll") { RemindersView() }.font(.subheadline.weight(.semibold))
                }
                ForEach(due, id: \.0.uid) { item in
                    ReminderRow(reminder: item.0, state: item.1) { paying = item.0 }
                }
            }
            .card()
            .sheet(item: $paying) { r in
                NavigationStack { MovementForm(movement: nil, prefill: r.dto) }.environmentObject(SyncService.shared)
            }
        }
    }
}

struct ReminderRow: View {
    let reminder: ReminderItem
    let state: MoneyTools.ReminderState
    let pay: () -> Void
    @Environment(\.modelContext) private var context

    private var when: String {
        switch state.status {
        case .paid: return L("reminders.paid")
        case .late: return String(localized: "reminders.late \(-state.days)")
        case .today: return L("reminders.today")
        default: return state.days == 1 ? L("reminders.tomorrow") : String(localized: "reminders.inDays \(state.days)")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "bell.fill", colors: [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)], size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: reminder.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(verbatim: [when, reminder.amountMinor.map { Formatting.money($0, reminder.currency ?? AppSettings.defaultCurrency) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(state.status == .late ? Theme.spend : state.status == .paid ? Color.secondary : state.days <= 3 ? Theme.warn : .secondary)
            }
            Spacer(minLength: 8)
            if state.status != .paid {
                Button {
                    reminder.paidMonth = MoneyTools.month(Date())
                    reminder.touch()
                    saveAndSync(context)
                    pay()
                } label: { Label("reminders.payNow", systemImage: "checkmark") }
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

/// Envelopes of this month in the summary's currency.
struct BudgetsCard: View {
    let currency: String
    let movements: [Movement]
    @Query(filter: #Predicate<BudgetItem> { $0.deleted == false }) private var all: [BudgetItem]
    @AppStorage("space") private var space = ""
    @State private var editing: BudgetItem?

    var body: some View {
        let list = all.inSpace(Spaces.valid(space)).filter { $0.currency == currency }
        if !list.isEmpty {
            let txs = movements.map(\.dto)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("budgets.title").font(.headline)
                    Spacer()
                    NavigationLink("month.seeAll") { BudgetsView() }.font(.subheadline.weight(.semibold))
                }
                ForEach(list, id: \.uid) { b in
                    BudgetRow(budget: b, state: MoneyTools.budget(b.dto, txs, month: MoneyTools.month(Date())))
                        .tapToEdit { editing = b }
                }
            }
            .card()
            .sheet(item: $editing) { b in NavigationStack { BudgetForm(budget: b) } }
        }
    }
}

struct BudgetRow: View {
    let budget: BudgetItem
    let state: MoneyTools.BudgetState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: budget.name).font(.body.weight(.semibold))
                Spacer()
                Text(verbatim: state.left >= 0
                     ? String(localized: "budgets.left \(Formatting.money(state.left, budget.currency))")
                     : String(localized: "budgets.over \(Formatting.money(-state.left, budget.currency))"))
                    .font(.subheadline.weight(state.level == .over ? .bold : .regular))
                    .foregroundStyle(state.level == .over ? Theme.spend : .secondary)
            }
            Meter(ratio: state.ratio, level: state.level)
            Text(verbatim: String(localized: "budgets.of \(Formatting.money(state.spent, budget.currency)) \(Formatting.money(budget.amountMinor, budget.currency))"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Savings pots with balance and goal.
struct PotsCard: View {
    let movements: [Movement]
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var all: [PotItem]
    @AppStorage("space") private var space = ""
    @State private var editing: PotItem?

    var body: some View {
        let list = all.inSpace(Spaces.valid(space))
        if !list.isEmpty {
            let txs = movements.map(\.dto)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("pots.title").font(.headline)
                    Spacer()
                    NavigationLink("month.seeAll") { PotsView() }.font(.subheadline.weight(.semibold))
                }
                ForEach(list, id: \.uid) { p in
                    PotRow(pot: p, state: MoneyTools.pot(p.dto, txs))
                        .tapToEdit { editing = p }
                }
            }
            .card()
            .sheet(item: $editing) { p in NavigationStack { PotForm(pot: p) } }
        }
    }
}

struct PotRow: View {
    let pot: PotItem
    let state: MoneyTools.PotState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: pot.name).font(.body.weight(.semibold))
                Spacer()
                Text(verbatim: Formatting.money(state.balance, pot.currency)).font(.body.weight(.bold)).monospacedDigit()
            }
            if let goal = state.goal, let progress = state.progress {
                Meter(ratio: progress)
                Text(verbatim: String(localized: "pots.goal \(Int((progress * 100).rounded())) \(Formatting.money(goal, pot.currency))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Management screens

/// What is still missing before a form can be saved, shown under its fields (instead of a Save button
/// that does nothing).
private struct MissingNote: View {
    let key: LocalizedStringKey?
    var body: some View {
        if let key { Text(key).foregroundStyle(Theme.warn) }
    }
}

private func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

/// A positive amount, or nil when the text is not one.
private func positiveAmount(_ text: String, _ currency: String) -> Int64? {
    guard let minor = AmountParser.parse(text, defaultCurrency: currency)?.minor, minor > 0 else { return nil }
    return minor
}

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<BudgetItem> { $0.deleted == false }) private var all: [BudgetItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @AppStorage("space") private var space = ""
    @State private var adding = false
    @State private var editing: BudgetItem?

    var body: some View {
        let list = all.inSpace(Spaces.valid(space))
        let txs = movements.inSpace(Spaces.valid(space)).map(\.dto)
        List {
            Section {
                if list.isEmpty { Text("budgets.empty").foregroundStyle(.secondary) }
                ForEach(list, id: \.uid) { b in
                    BudgetRow(budget: b, state: MoneyTools.budget(b.dto, txs, month: MoneyTools.month(Date())))
                        .tapToEdit { editing = b }
                }
                .onDelete { idx in
                    for i in idx { list[i].deleted = true; list[i].touch() }
                    saveAndSync(context)
                }
            } footer: {
                Text("budgets.hint")
            }
        }
        .navigationTitle("budgets.title")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Label("budgets.create", systemImage: "plus") } } }
        .sheet(isPresented: $adding) { NavigationStack { BudgetForm() } }
        .sheet(item: $editing) { b in NavigationStack { BudgetForm(budget: b) } }
    }
}

/// New or existing envelope: name, monthly limit and the categories that count. Editing also shows
/// what went into it this month.
struct BudgetForm: View {
    let budget: BudgetItem?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false && $0.kind == "expense" }) private var expenses: [Movement]
    @AppStorage("space") private var space = ""
    @State private var name: String
    @State private var amount: String
    @State private var currency: String
    @State private var picked: Set<String>
    @State private var confirmDelete = false

    /// The server keeps at most this many categories per envelope.
    private static let maxCategories = 20

    init(budget: BudgetItem? = nil) {
        self.budget = budget
        _name = State(initialValue: budget?.name ?? "")
        _amount = State(initialValue: budget.map { Formatting.editable($0.amountMinor, $0.currency) } ?? "")
        _currency = State(initialValue: budget?.currency ?? AppSettings.defaultCurrency)
        _picked = State(initialValue: Set(budget?.categoryIds ?? []))
    }

    private var spaceId: String { budget?.space ?? Spaces.valid(space) }
    private var categories: [CategoryItem] { allCategories.inSpace(spaceId).sorted { $0.displayName < $1.displayName } }
    /// The picked categories that still exist, in a stable order.
    private var chosen: [String] { categories.map(\.id).filter { picked.contains($0) } }

    private var missing: LocalizedStringKey? {
        if cleaned(name).isEmpty { return "budgets.needName" }
        if positiveAmount(amount, currency) == nil { return "budgets.needAmount" }
        if chosen.isEmpty { return "budgets.needCategories" }
        if chosen.count > Self.maxCategories { return "budgets.tooManyCategories" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("budgets.name", text: $name)
                HStack {
                    TextField("budgets.amount", text: $amount).keyboardType(.decimalPad)
                    CurrencyPicker(currency: $currency).labelsHidden().fixedSize()
                }
            } footer: {
                MissingNote(key: missing)
            }
            Section("budgets.categories") {
                ForEach(categories, id: \.uid) { c in
                    Button {
                        if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                    } label: {
                        HStack {
                            Tile(look: Looks.of(c))
                            Text(verbatim: c.displayName).foregroundStyle(.primary)
                            Spacer()
                            if picked.contains(c.id) { Image(systemName: "checkmark").foregroundStyle(Theme.earn) }
                        }
                    }
                }
            }
            if let budget {
                let month = MoneyTools.month(Date())
                let ids = Set(budget.categoryIds)
                let inside = expenses
                    .filter { $0.space == budget.space && $0.currency == budget.currency && MoneyTools.month($0.occurredAt) == month && ids.contains($0.categoryId ?? "") }
                    .sorted { $0.occurredAt > $1.occurredAt }
                Section("budgets.thisMonth") {
                    if inside.isEmpty { Text("budgets.nothingYet").foregroundStyle(.secondary) }
                    ForEach(inside.prefix(50)) { m in MovementRow(movement: m, category: categories.first { $0.id == m.categoryId }) }
                }
                Section {
                    Button("budgets.delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(budget == nil ? "budgets.new" : "budgets.edit")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("form.save", action: save).disabled(missing != nil) }
        }
        .confirmationDialog("budgets.confirmDelete", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("form.delete", role: .destructive) {
                budget?.deleted = true
                budget?.touch()
                saveAndSync(context)
                dismiss()
            }
        }
    }

    private func save() {
        guard missing == nil, let limit = positiveAmount(amount, currency) else { return }
        let n = String(cleaned(name).prefix(100))
        let dto = BudgetDTO(id: budget?.id ?? UUID().uuidString, name: n, amount_minor: limit, currency: currency, category_ids: chosen,
                            updated_at: SyncRules.now(), space_id: Spaces.wire(spaceId))
        if let b = budget {
            b.name = n
            b.amountMinor = limit
            b.currency = currency
            b.categoryIdsJSON = dto.category_ids
            b.touch()
        } else {
            context.insert(BudgetItem(dto, dirty: true))
        }
        saveAndSync(context)
        dismiss()
    }
}

struct PotsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var all: [PotItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @AppStorage("space") private var space = ""
    @State private var adding = false
    @State private var editing: PotItem?
    @State private var moving: (pot: PotItem, kind: String)?
    @State private var amount = ""

    var body: some View {
        let list = all.inSpace(Spaces.valid(space))
        let txs = movements.map(\.dto)
        List {
            Section {
                if list.isEmpty { Text("pots.empty").foregroundStyle(.secondary) }
                ForEach(list, id: \.uid) { p in
                    VStack(alignment: .leading, spacing: 10) {
                        PotRow(pot: p, state: MoneyTools.pot(p.dto, txs))
                        HStack {
                            Button { amount = ""; moving = (p, "saving") } label: { Label("pots.deposit", systemImage: "arrow.down") }
                            Button { amount = ""; moving = (p, "withdrawal") } label: { Label("pots.withdraw", systemImage: "arrow.up") }
                            Button { editing = p } label: { Label("form.edit", systemImage: "pencil") }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                    }
                    .tapToEdit { editing = p }
                }
                .onDelete { idx in
                    for i in idx { list[i].deleted = true; list[i].touch() }
                    saveAndSync(context)
                }
            } footer: {
                Text("pots.hint")
            }
        }
        .navigationTitle("pots.title")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Label("pots.create", systemImage: "plus") } } }
        .sheet(isPresented: $adding) { NavigationStack { PotForm() } }
        .sheet(item: $editing) { p in NavigationStack { PotForm(pot: p) } }
        .alert(Text(verbatim: moving.map { prompt(for: $0.pot, kind: $0.kind) } ?? ""),
               isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            TextField("form.amount", text: $amount).keyboardType(.decimalPad)
            Button("form.save") { if let m = moving { record(m.pot, m.kind) } }
            Button("app.cancel", role: .cancel) {}
        }
    }

    private func prompt(for pot: PotItem, kind: String) -> String {
        if kind == "saving" { return String(localized: "pots.depositPrompt \(pot.name)") }
        return String(localized: "pots.withdrawPrompt \(pot.name)")
    }

    private func record(_ pot: PotItem, _ kind: String) {
        guard let minor = positiveAmount(amount, pot.currency) else { return }
        context.insert(Movement(TransactionDTO(id: UUID().uuidString, kind: kind, amount_minor: minor, currency: pot.currency,
                                               merchant: pot.name, source: "manual", occurred_at: ISODate.string(Date()),
                                               updated_at: SyncRules.now(), space_id: Spaces.wire(pot.space), pot_id: pot.id), dirty: true))
        saveAndSync(context)
    }
}

/// New or existing savings pot: name, currency, optional goal and date. Editing also shows its
/// deposits, withdrawals and the expenses paid from it.
struct PotForm: View {
    let pot: PotItem?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Movement> { $0.deleted == false && $0.potId != nil }) private var potMovements: [Movement]
    @AppStorage("space") private var space = ""
    @State private var name: String
    @State private var currency: String
    @State private var goal: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var confirmDelete = false

    init(pot: PotItem? = nil) {
        self.pot = pot
        _name = State(initialValue: pot?.name ?? "")
        _currency = State(initialValue: pot?.currency ?? AppSettings.defaultCurrency)
        _goal = State(initialValue: pot.flatMap { p in p.goalMinor.map { Formatting.editable($0, p.currency) } } ?? "")
        _hasDate = State(initialValue: pot?.goalDate != nil)
        _date = State(initialValue: pot?.goalDate.flatMap { ISODate.day(from: $0) } ?? Date())
    }

    private var history: [Movement] {
        guard let pot else { return [] }
        return potMovements.filter { $0.potId == pot.id && $0.space == pot.space }.sorted { $0.occurredAt > $1.occurredAt }
    }

    private var missing: LocalizedStringKey? {
        if cleaned(name).isEmpty { return "pots.needName" }
        if !cleaned(goal).isEmpty && positiveAmount(goal, currency) == nil { return "pots.badGoal" }
        return nil
    }

    var body: some View {
        let entries = history
        Form {
            Section {
                TextField("pots.name", text: $name)
                CurrencyPicker(currency: $currency).disabled(!entries.isEmpty)
                TextField("pots.goalOptional", text: $goal).keyboardType(.decimalPad)
                Toggle("pots.goalDate", isOn: $hasDate)
                if hasDate { DatePicker("pots.goalDate", selection: $date, displayedComponents: .date) }
            } footer: {
                if missing != nil { MissingNote(key: missing) } else if !entries.isEmpty { Text("pots.currencyLocked") }
            }
            if pot != nil {
                Section("pots.history") {
                    if entries.isEmpty { Text("pots.noHistory").foregroundStyle(.secondary) }
                    ForEach(entries.prefix(50)) { m in MovementRow(movement: m, category: nil) }
                }
                Section {
                    Button("pots.delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(pot == nil ? "pots.new" : "pots.edit")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("form.save", action: save).disabled(missing != nil) }
        }
        .confirmationDialog("pots.confirmDelete", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("form.delete", role: .destructive) {
                pot?.deleted = true
                pot?.touch()
                saveAndSync(context)
                dismiss()
            }
        }
    }

    private func save() {
        guard missing == nil else { return }
        let n = String(cleaned(name).prefix(100))
        let goalMinor = cleaned(goal).isEmpty ? nil : positiveAmount(goal, currency)
        // The day where the person is, not the UTC day (a date picked in the evening would move).
        let day = hasDate ? ISODate.day(date) : nil
        if let p = pot {
            p.name = n
            p.currency = currency
            p.goalMinor = goalMinor
            p.goalDate = day
            p.touch()
        } else {
            context.insert(PotItem(PotDTO(id: UUID().uuidString, name: n, currency: currency, goal_minor: goalMinor, goal_date: day,
                                          updated_at: SyncRules.now(), space_id: Spaces.wire(Spaces.valid(space))), dirty: true))
        }
        saveAndSync(context)
        dismiss()
    }
}

struct RemindersView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ReminderItem> { $0.deleted == false }) private var all: [ReminderItem]
    @AppStorage("space") private var space = ""
    @State private var adding = false
    @State private var editing: ReminderItem?
    @State private var paying: ReminderItem?

    var body: some View {
        let list = all.inSpace(Spaces.valid(space)).map { ($0, MoneyTools.reminder($0.dto)) }.sorted { $0.1.days < $1.1.days }
        List {
            Section {
                if list.isEmpty { Text("reminders.empty").foregroundStyle(.secondary) }
                ForEach(list, id: \.0.uid) { item in
                    ReminderRow(reminder: item.0, state: item.1) { paying = item.0 }
                        .tapToEdit { editing = item.0 }
                }
                .onDelete { idx in
                    for i in idx { list[i].0.deleted = true; list[i].0.touch() }
                    saveAndSync(context)
                }
            } footer: {
                Text("reminders.hint")
            }
        }
        .navigationTitle("reminders.title")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Label("reminders.create", systemImage: "plus") } } }
        .sheet(isPresented: $adding) { NavigationStack { ReminderForm() } }
        .sheet(item: $editing) { r in NavigationStack { ReminderForm(reminder: r) } }
        .sheet(item: $paying) { r in NavigationStack { MovementForm(movement: nil, prefill: r.dto) }.environmentObject(SyncService.shared) }
    }
}

/// New or existing reminder: what to pay, the day, an optional amount and category (they fill in
/// «Ya pagué»). Editing can also undo «Ya pagué» for this month.
struct ReminderForm: View {
    let reminder: ReminderItem?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @AppStorage("space") private var space = ""
    @State private var name: String
    @State private var day: Int
    @State private var amount: String
    @State private var currency: String
    @State private var categoryId: String?
    @State private var paid: Bool
    @State private var confirmDelete = false
    private let month = MoneyTools.month(Date())

    init(reminder: ReminderItem? = nil) {
        self.reminder = reminder
        _name = State(initialValue: reminder?.name ?? "")
        _day = State(initialValue: reminder?.dayOfMonth ?? Calendar.current.component(.day, from: Date()))
        _amount = State(initialValue: reminder.flatMap { r in r.amountMinor.map { Formatting.editable($0, r.currency ?? AppSettings.defaultCurrency) } } ?? "")
        _currency = State(initialValue: reminder?.currency ?? AppSettings.defaultCurrency)
        _categoryId = State(initialValue: reminder?.categoryId)
        _paid = State(initialValue: reminder?.paidMonth == MoneyTools.month(Date()))
    }

    private var spaceId: String { reminder?.space ?? Spaces.valid(space) }
    private var categories: [CategoryItem] { allCategories.inSpace(spaceId).sorted { $0.displayName < $1.displayName } }

    private var missing: LocalizedStringKey? {
        if cleaned(name).isEmpty { return "reminders.needName" }
        if !cleaned(amount).isEmpty && positiveAmount(amount, currency) == nil { return "form.invalidAmount" }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("reminders.name", text: $name)
                Stepper(value: $day, in: 1...31) { Text("reminders.dayValue \(day)") }
                HStack {
                    TextField("reminders.amountOptional", text: $amount).keyboardType(.decimalPad)
                    CurrencyPicker(currency: $currency).labelsHidden().fixedSize()
                }
                Picker("form.category", selection: $categoryId) {
                    Text("category.none").tag(String?.none)
                    ForEach(categories, id: \.uid) { c in Text(verbatim: c.displayName).tag(Optional(c.id)) }
                }
            } footer: {
                if missing != nil { MissingNote(key: missing) } else { Text("reminders.categoryHint") }
            }
            if reminder != nil {
                Section {
                    Toggle("reminders.paidThisMonth", isOn: $paid)
                } footer: {
                    Text("reminders.paidHint")
                }
                Section {
                    Button("reminders.delete", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(reminder == nil ? "reminders.new" : "reminders.edit")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .task { if reminder == nil { _ = await PaymentNotifier.requestPermission() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("form.save", action: save).disabled(missing != nil) }
        }
        .confirmationDialog("reminders.confirmDelete", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("form.delete", role: .destructive) {
                reminder?.deleted = true
                reminder?.touch()
                saveAndSync(context)
                dismiss()
            }
        }
    }

    private func save() {
        guard missing == nil else { return }
        let n = String(cleaned(name).prefix(100))
        let minor = cleaned(amount).isEmpty ? nil : positiveAmount(amount, currency)
        if let r = reminder {
            r.name = n
            r.dayOfMonth = day
            r.amountMinor = minor
            r.currency = minor == nil ? nil : currency
            r.categoryId = categoryId
            if paid { r.paidMonth = month } else if r.paidMonth == month { r.paidMonth = nil }
            r.touch()
        } else {
            context.insert(ReminderItem(ReminderDTO(id: UUID().uuidString, name: n, amount_minor: minor, currency: minor == nil ? nil : currency,
                                                    day_of_month: day, category_id: categoryId, updated_at: SyncRules.now(),
                                                    space_id: Spaces.wire(spaceId)), dirty: true))
        }
        saveAndSync(context)
        dismiss()
    }
}

/// Alert time and which alerts to get.
struct AlertsSettingsView: View {
    @AppStorage("alertsHour") private var hour = 9
    @AppStorage("fixedAlerts") private var fixed = true
    @AppStorage("reminderAlerts") private var reminders = true
    @AppStorage("budgetAlerts") private var budgets = true

    var body: some View {
        Form {
            Section {
                Toggle("alerts.fixedToggle", isOn: $fixed)
                Toggle("alerts.reminderToggle", isOn: $reminders)
                Toggle("alerts.budgetToggle", isOn: $budgets)
                Picker("alerts.hour", selection: $hour) {
                    ForEach(6...21, id: \.self) { h in Text(verbatim: String(format: "%02d:00", h)).tag(h) }
                }
            } footer: {
                Text("alerts.hint")
            }
        }
        .navigationTitle("alerts.title")
        .onChange(of: [fixed, reminders, budgets]) { _, _ in Task { await Reminders.reschedule() } }
        .onChange(of: hour) { _, _ in Task { await Reminders.reschedule() } }
        .task { _ = await PaymentNotifier.requestPermission() }
    }
}

// MARK: - Suggestions at the right moment (docs/design/onboarding.md)

/// One suggestion at a time in the summary: a fixed charge just found, an envelope once there is some
/// spending, a first savings pot once money came in. Each one can be dismissed for good.
struct NudgeCard: View {
    let movements: [Movement]
    let recurring: [Recurring]
    let currency: String
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<BudgetItem> { $0.deleted == false }) private var budgets: [BudgetItem]
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var pots: [PotItem]
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @AppStorage("space") private var space = ""
    @AppStorage("nudgesSeen") private var seen = ""
    @State private var creatingPot = false

    private enum Nudge {
        case fixed(Recurring)
        case budget(CategoryItem, spent: Int64, suggested: Int64)
        case pot
    }

    private func isSeen(_ key: String) -> Bool { seen.split(separator: "|").contains(Substring(key)) }
    private func markSeen(_ key: String) { withAnimation { seen = (seen.isEmpty ? key : seen + "|" + key) } }

    private var nudge: (key: String, value: Nudge)? {
        let current = Spaces.valid(space)
        if let r = recurring.first(where: { !isSeen("fixed:" + $0.key) }) { return ("fixed:" + r.key, .fixed(r)) }
        let monthExpenses = movements.filter { $0.kind == "expense" && $0.currency == currency && MoneyTools.month($0.occurredAt) == MoneyTools.month(Date()) }
        if budgets.inSpace(current).isEmpty, monthExpenses.count >= 10, !isSeen("budget:" + current) {
            let byCategory = Dictionary(grouping: monthExpenses.filter { $0.categoryId != nil }, by: { $0.categoryId! })
                .mapValues { $0.reduce(Int64(0)) { $0 + $1.amountMinor } }
            if let top = byCategory.max(by: { $0.value < $1.value }), let cat = categories.inSpace(current).first(where: { $0.id == top.key }) {
                let cal = Calendar.current
                let day = max(1, cal.component(.day, from: Date()))
                let days = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
                let projected = top.value * Int64(days) / Int64(day)
                let step: Int64 = currency == "CRC" ? 500_000 : 5_000
                return ("budget:" + current, .budget(cat, spent: top.value, suggested: max(step, (projected + step - 1) / step * step)))
            }
        }
        let income = movements.contains { $0.kind == "income" && MoneyTools.month($0.occurredAt) == MoneyTools.month(Date()) }
        if pots.inSpace(current).isEmpty, income, !isSeen("pot:" + current) { return ("pot:" + current, .pot) }
        return nil
    }

    var body: some View {
        if let item = nudge {
            let key = item.key
            VStack(alignment: .leading, spacing: 10) {
                switch item.value {
                case .fixed(let r):
                    Label { Text("nudge.fixedTitle \(r.merchant)").font(.headline) } icon: { Image(systemName: "repeat").foregroundStyle(Theme.brand) }
                    Text("nudge.fixedText \(Formatting.money(r.monthly, r.currency))").font(.subheadline).foregroundStyle(.secondary)
                    Button("nudge.ok") { markSeen(key) }.buttonStyle(ChipStyle())
                case .budget(let cat, let spent, let suggested):
                    Label { Text("nudge.budgetTitle").font(.headline) } icon: { Image(systemName: "tray.full.fill").foregroundStyle(Theme.brand) }
                    Text("nudge.budgetText \(Formatting.money(spent, currency)) \(cat.displayName)").font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button("nudge.budgetCreate \(Formatting.money(suggested, currency))") {
                            context.insert(BudgetItem(BudgetDTO(id: UUID().uuidString, name: cat.displayName, amount_minor: suggested, currency: currency,
                                                                category_ids: [cat.id], updated_at: SyncRules.now(), space_id: Spaces.wire(cat.space)), dirty: true))
                            try? context.save()
                            Task { await SyncService.shared.sync() }
                            markSeen(key)
                        }
                        .buttonStyle(BrandButtonStyle())
                        Button("onboarding.notNow") { markSeen(key) }.font(.subheadline.weight(.semibold))
                    }
                case .pot:
                    Label { Text("nudge.potTitle").font(.headline) } icon: { Image(systemName: "banknote.fill").foregroundStyle(Theme.brand) }
                    Text("nudge.potText").font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button("nudge.potCreate") { creatingPot = true }.buttonStyle(BrandButtonStyle())
                        Button("onboarding.notNow") { markSeen(key) }.font(.subheadline.weight(.semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .sheet(isPresented: $creatingPot, onDismiss: { if !pots.inSpace(Spaces.valid(space)).isEmpty { markSeen(key) } }) {
                NavigationStack { PotForm() }
            }
        }
    }
}
