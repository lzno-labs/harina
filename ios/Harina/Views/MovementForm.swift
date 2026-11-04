// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// New or existing movement. Built for speed: amount first, keyboard up, one tap to save.
struct MovementForm: View {
    let movement: Movement?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @Query(filter: #Predicate<AccountItem> { $0.deleted == false }) private var accounts: [AccountItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var movements: [Movement]

    @State private var kind = "expense"
    @State private var amount = ""
    @State private var currency = AppSettings.defaultCurrency
    @State private var categoryId: String?
    @State private var accountId: String?
    @State private var date = Date()
    @State private var merchant = ""
    @State private var note = ""
    @State private var invalid = false
    @State private var saved = false
    @FocusState private var amountFocused: Bool

    var body: some View {
        Form {
            Picker("form.kind", selection: $kind) {
                Text("form.expense").tag("expense")
                Text("form.income").tag("income")
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("form.amount", text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.largeTitle)
                    .focused($amountFocused)
                Picker("form.currency", selection: $currency) {
                    Text(verbatim: "CRC").tag("CRC")
                    Text(verbatim: "USD").tag("USD")
                }
                .labelsHidden()
            }
            if let raw = movement?.rawAmount { Text("review.rawAmount \(raw)").font(.caption).foregroundStyle(.secondary) }
            TextField("form.merchant", text: $merchant)
            Picker("form.category", selection: $categoryId) {
                Text("category.none").tag(String?.none)
                ForEach(categories.sorted { $0.displayName < $1.displayName }) { Text($0.displayName).tag(Optional($0.id)) }
            }
            if categoryId == nil, let s = Suggestion.category(for: merchant, in: movements, categories: categories) {
                Button("form.suggested \(s.displayName)") { categoryId = s.id }
            }
            Picker("form.account", selection: $accountId) {
                Text("form.noAccount").tag(String?.none)
                ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
            }
            DatePicker("form.date", selection: $date)
            TextField("form.note", text: $note)
            Section {
                Button("form.save", action: save).bold()
                if movement != nil {
                    Button("form.delete", role: .destructive) {
                        movement?.deleted = true
                        movement?.touch()
                        finish()
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey(movement == nil ? "form.titleNew" : "form.titleEdit"))
        .alert("form.invalidAmount", isPresented: $invalid) {}
        .sensoryFeedback(.success, trigger: saved)
        .onAppear(perform: load)
    }

    private func load() {
        guard let m = movement else {
            amountFocused = true
            return
        }
        kind = m.kind; currency = m.currency; categoryId = m.categoryId; accountId = m.accountId
        date = m.occurredAt; merchant = m.merchant ?? ""; note = m.note ?? ""
        amount = m.needsReview && m.amountMinor == 0 ? "" : Formatting.editable(m.amountMinor, m.currency)
    }

    private func save() {
        guard let parsed = AmountParser.parse(amount, defaultCurrency: currency) else {
            invalid = true
            return
        }
        let m = movement ?? { () -> Movement in
            let dto = TransactionDTO(id: UUID().uuidString, kind: kind, amount_minor: 0, currency: currency, source: "manual",
                                     occurred_at: ISODate.string(date), updated_at: SyncRules.now())
            let new = Movement(dto, dirty: true)
            context.insert(new)
            return new
        }()
        m.kind = kind
        m.amountMinor = parsed.minor
        m.currency = currency
        m.categoryId = categoryId
        m.accountId = accountId
        m.occurredAt = date
        m.merchant = merchant.isEmpty ? nil : String(merchant.prefix(200))
        m.note = note.isEmpty ? nil : String(note.prefix(1000))
        m.needsReview = false
        m.touch()
        finish()
    }

    private func finish() {
        try? context.save()
        saved.toggle()
        Task { await sync.sync() }
        if movement != nil {
            dismiss()
        } else {
            amount = ""; merchant = ""; note = ""; categoryId = nil; date = Date()
            amountFocused = true
        }
    }
}
