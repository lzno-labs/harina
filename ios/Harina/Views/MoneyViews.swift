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
                ForEach(list, id: \.uid) { b in BudgetRow(budget: b, state: MoneyTools.budget(b.dto, txs, month: MoneyTools.month(Date()))) }
            }
            .card()
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
                ForEach(list, id: \.uid) { p in PotRow(pot: p, state: MoneyTools.pot(p.dto, txs)) }
            }
            .card()
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

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<BudgetItem> { $0.deleted == false }) private var all: [BudgetItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @AppStorage("space") private var space = ""
    @State private var adding = false

    var body: some View {
        let list = all.inSpace(Spaces.valid(space))
        let txs = movements.inSpace(Spaces.valid(space)).map(\.dto)
        List {
            Section {
                if list.isEmpty { Text("budgets.empty").foregroundStyle(.secondary) }
                ForEach(list, id: \.uid) { b in BudgetRow(budget: b, state: MoneyTools.budget(b.dto, txs, month: MoneyTools.month(Date()))) }
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
    }
}

struct BudgetForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @AppStorage("space") private var space = ""
    @State private var name = ""
    @State private var amount = ""
    @State private var currency = AppSettings.defaultCurrency
    @State private var picked = Set<String>()

    var body: some View {
        Form {
            TextField("budgets.name", text: $name)
            HStack {
                TextField("budgets.amount", text: $amount).keyboardType(.decimalPad)
                Picker("form.currency", selection: $currency) { Text(verbatim: "CRC").tag("CRC"); Text(verbatim: "USD").tag("USD") }
                    .labelsHidden()
            }
            Section("budgets.categories") {
                ForEach(allCategories.inSpace(Spaces.valid(space)).sorted { $0.displayName < $1.displayName }, id: \.uid) { c in
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
        }
        .navigationTitle("budgets.new")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("spaces.save") {
                    guard let parsed = AmountParser.parse(amount, defaultCurrency: currency), parsed.minor > 0, !picked.isEmpty,
                          !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    context.insert(BudgetItem(BudgetDTO(id: UUID().uuidString, name: String(name.trimmingCharacters(in: .whitespaces).prefix(100)),
                                                        amount_minor: parsed.minor, currency: currency, category_ids: Array(picked),
                                                        updated_at: SyncRules.now(), space_id: Spaces.wire(Spaces.valid(space))), dirty: true))
                    saveAndSync(context)
                    dismiss()
                }
            }
        }
    }
}

struct PotsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var all: [PotItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]
    @AppStorage("space") private var space = ""
    @State private var adding = false
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
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.semibold))
                    }
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
        .alert(Text(verbatim: moving.map { prompt(for: $0.pot, kind: $0.kind) } ?? ""),
               isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            TextField("form.amount", text: $amount).keyboardType(.decimalPad)
            Button("spaces.save") { if let m = moving { record(m.pot, m.kind) } }
            Button("app.cancel", role: .cancel) {}
        }
    }

    private func prompt(for pot: PotItem, kind: String) -> String {
        if kind == "saving" { return String(localized: "pots.depositPrompt \(pot.name)") }
        return String(localized: "pots.withdrawPrompt \(pot.name)")
    }

    private func record(_ pot: PotItem, _ kind: String) {
        guard let parsed = AmountParser.parse(amount, defaultCurrency: pot.currency), parsed.minor > 0 else { return }
        context.insert(Movement(TransactionDTO(id: UUID().uuidString, kind: kind, amount_minor: parsed.minor, currency: pot.currency,
                                               merchant: pot.name, source: "manual", occurred_at: ISODate.string(Date()),
                                               updated_at: SyncRules.now(), space_id: Spaces.wire(pot.space), pot_id: pot.id), dirty: true))
        saveAndSync(context)
    }
}

struct PotForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("space") private var space = ""
    @State private var name = ""
    @State private var currency = AppSettings.defaultCurrency
    @State private var goal = ""
    @State private var hasDate = false
    @State private var date = Date()

    var body: some View {
        Form {
            TextField("pots.name", text: $name)
            Picker("form.currency", selection: $currency) { Text(verbatim: "CRC").tag("CRC"); Text(verbatim: "USD").tag("USD") }
            TextField("pots.goalOptional", text: $goal).keyboardType(.decimalPad)
            Toggle("pots.goalDate", isOn: $hasDate)
            if hasDate { DatePicker("pots.goalDate", selection: $date, displayedComponents: .date) }
        }
        .navigationTitle("pots.new")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("spaces.save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    let goalMinor = goal.isEmpty ? nil : AmountParser.parse(goal, defaultCurrency: currency)?.minor
                    let day = hasDate ? String(ISODate.string(date).prefix(10)) : nil
                    context.insert(PotItem(PotDTO(id: UUID().uuidString, name: String(n.prefix(100)), currency: currency, goal_minor: goalMinor,
                                                  goal_date: day, updated_at: SyncRules.now(), space_id: Spaces.wire(Spaces.valid(space))), dirty: true))
                    saveAndSync(context)
                    dismiss()
                }
            }
        }
    }
}

struct RemindersView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ReminderItem> { $0.deleted == false }) private var all: [ReminderItem]
    @AppStorage("space") private var space = ""
    @State private var adding = false
    @State private var paying: ReminderItem?

    var body: some View {
        let list = all.inSpace(Spaces.valid(space)).map { ($0, MoneyTools.reminder($0.dto)) }.sorted { $0.1.days < $1.1.days }
        List {
            Section {
                if list.isEmpty { Text("reminders.empty").foregroundStyle(.secondary) }
                ForEach(list, id: \.0.uid) { item in ReminderRow(reminder: item.0, state: item.1) { paying = item.0 } }
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
        .sheet(item: $paying) { r in NavigationStack { MovementForm(movement: nil, prefill: r.dto) }.environmentObject(SyncService.shared) }
    }
}

struct ReminderForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("space") private var space = ""
    @State private var name = ""
    @State private var day = Calendar.current.component(.day, from: Date())
    @State private var amount = ""
    @State private var currency = AppSettings.defaultCurrency

    var body: some View {
        Form {
            TextField("reminders.name", text: $name)
            Stepper(value: $day, in: 1...31) { Text("reminders.dayValue \(day)") }
            HStack {
                TextField("reminders.amountOptional", text: $amount).keyboardType(.decimalPad)
                Picker("form.currency", selection: $currency) { Text(verbatim: "CRC").tag("CRC"); Text(verbatim: "USD").tag("USD") }
                    .labelsHidden()
            }
        }
        .navigationTitle("reminders.new")
        .task { _ = await PaymentNotifier.requestPermission() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("spaces.save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    let minor = amount.isEmpty ? nil : AmountParser.parse(amount, defaultCurrency: currency)?.minor
                    context.insert(ReminderItem(ReminderDTO(id: UUID().uuidString, name: String(n.prefix(100)), amount_minor: minor,
                                                            currency: minor == nil ? nil : currency, day_of_month: day,
                                                            updated_at: SyncRules.now(), space_id: Spaces.wire(Spaces.valid(space))), dirty: true))
                    saveAndSync(context)
                    dismiss()
                }
            }
        }
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
