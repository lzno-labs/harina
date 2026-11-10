// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// New or existing movement. Built for speed: amount first, keyboard up, one tap per choice.
struct MovementForm: View {
    let movement: Movement?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @AppStorage("space") private var spaceC = ""
    private var categories: [CategoryItem] { allCategories.inSpace(Spaces.valid(spaceC)) }
    @Query(filter: #Predicate<AccountItem> { $0.deleted == false }) private var allAccounts: [AccountItem]
    @AppStorage("space") private var spaceA = ""
    private var accounts: [AccountItem] { allAccounts.inSpace(Spaces.valid(spaceA)) }
    @Query(filter: #Predicate<Movement> { $0.deleted == false }) private var allMovements: [Movement]
    @AppStorage("space") private var spaceM = ""
    private var movements: [Movement] { allMovements.inSpace(Spaces.valid(spaceM)) }

    @State private var kind = "expense"
    @State private var amount = ""
    @State private var currency = AppSettings.defaultCurrency
    @State private var categoryId: String?
    @State private var accountId: String?
    @State private var date = Date()
    @State private var merchant = ""
    @State private var note = ""
    @State private var invalid = false
    @State private var moveFailed = false
    @State private var saved = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool
    /// Built once per screen: the model is retrained from all labels, so not on every keystroke.
    @State private var brain: Brain?

    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 8)]

    var body: some View {
        let suggestion: CategoryItem? = {
            guard categoryId == nil, let brain else { return nil }
            let d = brain.model.decide(brain.calibration, DecisionState(merchant: merchant, card: nil, amountMinor: nil, currency: currency))
            return d.band == .ask ? nil : brain.category(d.categoryId)
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("form.kind", selection: $kind) {
                    Text("form.expense").tag("expense")
                    Text("form.income").tag("income")
                }
                .pickerStyle(.segmented)

                VStack(spacing: 10) {
                    Button {
                        currency = currency == "CRC" ? "USD" : "CRC"
                    } label: {
                        Text(verbatim: currency).font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(ChipStyle())
                    .accessibilityLabel("form.currency")
                    TextField("form.amountPlaceholder", text: $amount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 56, weight: .heavy))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .focused($amountFocused)
                        .foregroundStyle(kind == "income" ? Theme.earn : Color.primary)
                    if let raw = movement?.rawAmount {
                        Text("review.rawAmount \(raw)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                field("form.merchant") {
                    TextField("form.merchant", text: $merchant)
                        .padding(13)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                field("form.category") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(categories.sorted { $0.displayName < $1.displayName }) { c in
                            let selected = categoryId == c.id
                            Button {
                                withAnimation(.snappy) { categoryId = selected ? nil : c.id }
                            } label: {
                                VStack(spacing: 6) {
                                    Tile(look: Looks.of(c), size: 36)
                                    Text(c.displayName).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(selected ? Color(hex: 0xFF6A4D) : .clear, lineWidth: 2)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if suggestion?.id == c.id {
                                        Label("form.suggestedShort", systemImage: "sparkles")
                                            .font(.caption2.weight(.heavy))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.brandHorizontal, in: Capsule())
                                            .offset(x: 4, y: -7)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !accounts.isEmpty {
                    field("form.account") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(accounts) { a in
                                    Button {
                                        accountId = accountId == a.id ? nil : a.id
                                    } label: {
                                        Label(a.name, systemImage: "creditcard")
                                    }
                                    .buttonStyle(ChipStyle(selected: accountId == a.id))
                                }
                            }
                        }
                    }
                }

                field("form.date") {
                    DatePicker("form.date", selection: $date).labelsHidden()
                }

                field("form.note") {
                    TextField("form.note", text: $note)
                        .padding(13)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Button(action: save) {
                    Label(LocalizedStringKey(kind == "income" ? "form.saveIncome" : "form.saveExpense"), systemImage: "checkmark")
                }
                .buttonStyle(BrandButtonStyle())
                .padding(.top, 4)

                if movement != nil {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("form.delete", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle(LocalizedStringKey(movement == nil ? "form.titleNew" : "form.titleEdit"))
        // The summary hides its navigation bar; the editor always shows it (back, and delete).
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if movement != nil {
                if let m = movement, sync.spaces.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(sync.spaces.filter { Spaces.local($0.id) != m.space }) { sp in
                                Button(Spaces.name(Spaces.local(sp.id))) {
                                    Task {
                                        do {
                                            try await sync.move(m, to: Spaces.local(sp.id))
                                            dismiss()
                                        } catch {
                                            moveFailed = true
                                        }
                                    }
                                }
                            }
                        } label: { Label("spaces.moveTo", systemImage: "arrow.left.arrow.right") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("form.delete", systemImage: "trash") }
                        .tint(Theme.spend)
                }
            }
        }
        .alert("form.invalidAmount", isPresented: $invalid) {}
        .alert("spaces.moveFailed", isPresented: $moveFailed) {}
        .confirmationDialog("form.confirmDelete", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("form.delete", role: .destructive) {
                movement?.deleted = true
                movement?.touch()
                finish()
            }
        }
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            load()
            brain = Smart.brain(movements: movements, categories: categories)
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
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
                                     occurred_at: ISODate.string(date), updated_at: SyncRules.now(),
                                     space_id: Spaces.wire(Spaces.valid(spaceM)))
            let new = Movement(dto, dirty: true)
            context.insert(new)
            return new
        }()
        m.kind = kind
        m.amountMinor = parsed.minor
        m.currency = currency
        m.setCategory(byPerson: categoryId)
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
