// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// New or existing movement. Built for speed: amount first, keyboard up, one tap per choice.
struct MovementForm: View {
    let movement: Movement?
    /// A reminder being paid («Ya pagué»): fills in the new movement.
    var prefill: ReminderDTO? = nil
    /// The «Anotar» tab: called after a new movement is saved, so the screen can move on and confirm it.
    var onSaved: ((Movement) -> Void)? = nil
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
    @State private var potId: String?
    /// The category was set by the decision model, not by the person (shown with ✨, `category_auto` 1).
    @State private var autoPicked = false
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var allPots: [PotItem]
    @State private var saved = false
    @State private var confirmDelete = false
    /// Which field has the keyboard; the keyboard bar moves between them and hides it.
    private enum Field: Hashable { case amount, merchant, note }
    @FocusState private var focus: Field?
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

                let pots = allPots.inSpace(movement?.space ?? Spaces.valid(spaceM))
                if !pots.isEmpty && kind == "expense" {
                    Picker(selection: $potId) {
                        Text("pots.notFromSavings").tag(String?.none)
                        ForEach(pots, id: \.uid) { p in Text(verbatim: p.name).tag(Optional(p.id)) }
                    } label: {
                        Label("pots.payWith", systemImage: "banknote")
                    }
                    .pickerStyle(.menu)
                }

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
                        .focused($focus, equals: .amount)
                        .foregroundStyle(kind == "income" ? Theme.earn : Color.primary)
                    if let raw = movement?.rawAmount {
                        Text("review.rawAmount \(raw)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                field("form.merchant") {
                    TextField("form.merchant", text: $merchant)
                        .focused($focus, equals: .merchant)
                        .submitLabel(.next)
                        .onSubmit { focus = .note }
                        .onChange(of: merchant) { _, _ in preselect() }
                        .padding(13)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                field("form.category") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(categories.sorted { $0.displayName < $1.displayName }) { c in
                            let selected = categoryId == c.id
                            Button {
                                withAnimation(.snappy) {
                                    categoryId = selected && !autoPicked ? nil : c.id
                                    autoPicked = false
                                }
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
                                    if suggestion?.id == c.id || (autoPicked && categoryId == c.id) {
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
                        .focused($focus, equals: .note)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
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
            // The decimal pad has no return key: «Siguiente» goes on to the merchant, «Listo» hides it.
            ToolbarItemGroup(placement: .keyboard) {
                if focus == .amount {
                    Button("form.next") { focus = .merchant }
                }
                Spacer()
                Button("app.done") { focus = nil }.fontWeight(.semibold)
            }
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
                finish(nil)
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
            if let p = prefill {
                merchant = p.name
                currency = p.currency ?? currency
                categoryId = p.category_id
                accountId = p.account_id
                if let a = p.amount_minor { amount = Formatting.editable(a, currency) }
            }
            if prefill?.amount_minor == nil { focus = .amount }
            return
        }
        potId = m.potId
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
        if movement == nil && autoPicked {
            m.categoryId = categoryId
            m.categoryAuto = 1
        } else {
            m.setCategory(byPerson: categoryId)
        }
        m.accountId = accountId
        if m.kind == "expense" || m.kind == "saving" || m.kind == "withdrawal" { m.potId = potId } else { m.potId = nil }
        m.occurredAt = date
        m.merchant = merchant.isEmpty ? nil : String(merchant.prefix(200))
        m.note = note.isEmpty ? nil : String(note.prefix(1000))
        m.needsReview = false
        m.touch()
        let needsCategory = movement == nil && categoryId == nil && kind == "expense" && AppSettings.autoCategory
        finish(movement == nil ? m : nil)
        // Nothing chosen: the same steps as an Apple Pay payment (history, then Apple Intelligence or the
        // hosted model if the person turned it on). Sure: it is set with ✨; otherwise it waits in «Por revisar».
        if needsCategory {
            let space = m.space
            Task {
                let decision = await Smart.categorize(m.dto, brain: Smart.brain(context, space: space))
                guard m.categoryId == nil else { return }
                if decision.band == .act, let id = decision.categoryId {
                    m.categoryId = id
                    m.categoryAuto = 1
                    m.touch()
                    try? context.save()
                    await sync.sync()
                } else if let id = Smart.suggestion(decision) {
                    // Not sure enough: it waits in «Por revisar» with this category first.
                    m.suggestedCategoryId = id
                    try? context.save()
                }
            }
        }
    }

    /// While typing the merchant of a new expense: if the history is sure, its category is selected.
    private func preselect() {
        guard movement == nil, kind == "expense", AppSettings.autoCategory, categoryId == nil || autoPicked, let brain else { return }
        let d = brain.model.decide(brain.calibration, DecisionState(merchant: merchant, card: nil, amountMinor: nil, currency: currency))
        withAnimation(.snappy) {
            if d.band == .act, let id = d.categoryId, brain.category(id) != nil {
                categoryId = id
                autoPicked = true
            } else if autoPicked {
                categoryId = nil
                autoPicked = false
            }
        }
    }

    /// `new`: the movement just created, if any.
    private func finish(_ new: Movement?) {
        try? context.save()
        saved.toggle()
        focus = nil
        Task { await sync.sync() }
        if movement != nil || prefill != nil || onSaved == nil {
            dismiss()
        } else {
            // The «Anotar» tab: clear it for next time and let the tab bar take the person back.
            amount = ""; merchant = ""; note = ""; categoryId = nil; autoPicked = false; date = Date(); potId = nil
            if let new { onSaved?(new) }
        }
    }
}
