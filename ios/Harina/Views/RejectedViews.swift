// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// Changes the server refused (docs/adr/0008-partial-push.md): what each one is, why, and a tap to
/// fix or delete it. Everything else keeps syncing meanwhile.
struct RejectedChangesView: View {
    @EnvironmentObject private var sync: SyncService
    @Environment(\.modelContext) private var context
    @State private var editing: RejectedItem?

    var body: some View {
        List {
            Section {
                ForEach(sync.rejected, id: \.key) { change in
                    let item = resolve(change)
                    Button { editing = item } label: { RejectedRow(change: change, item: item) }
                        .disabled(item == nil)
                }
            } footer: {
                Text("rejected.footer")
            }
        }
        .navigationTitle("rejected.title")
        .refreshable { await sync.sync() }
        .sheet(item: $editing, onDismiss: { Task { await sync.sync() } }) { item in editor(item) }
    }

    @ViewBuilder private func editor(_ item: RejectedItem) -> some View {
        switch item {
        case .movement(let m): NavigationStack { MovementForm(movement: m) }.environmentObject(sync)
        case .account(let a): NavigationStack { AccountForm(account: a) }.environmentObject(sync)
        case .category(let c): CategoryEditor(category: c).environmentObject(sync)
        case .reminder(let r): NavigationStack { ReminderForm(reminder: r) }
        case .budget(let b): NavigationStack { BudgetForm(budget: b) }
        case .pot(let p): NavigationStack { PotForm(pot: p) }
        }
    }

    /// The local record a refused change belongs to, if it is still on this iPhone.
    private func resolve(_ change: RejectedChange) -> RejectedItem? {
        let id = change.id
        let uid = Spaces.uid(Spaces.local(change.space_id), id)
        switch change.entity {
        case "transactions":
            return (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.id == id })).first).map { RejectedItem.movement($0) }
        case "accounts":
            return (try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.id == id })).first).map { RejectedItem.account($0) }
        case "categories":
            return (try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.uid == uid })).first).map { RejectedItem.category($0) }
        case "reminders":
            return (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.uid == uid })).first).map { RejectedItem.reminder($0) }
        case "budgets":
            return (try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.uid == uid })).first).map { RejectedItem.budget($0) }
        case "pots":
            return (try? context.fetch(FetchDescriptor<PotItem>(predicate: #Predicate { $0.uid == uid })).first).map { RejectedItem.pot($0) }
        default:
            return nil
        }
    }
}

/// A refused record on this iPhone, ready to open in its editor.
enum RejectedItem: Identifiable {
    case movement(Movement), account(AccountItem), category(CategoryItem), reminder(ReminderItem), budget(BudgetItem), pot(PotItem)

    var id: String {
        switch self {
        case .movement(let m): return "m:" + m.id
        case .account(let a): return "a:" + a.id
        case .category(let c): return "c:" + c.uid
        case .reminder(let r): return "r:" + r.uid
        case .budget(let b): return "b:" + b.uid
        case .pot(let p): return "p:" + p.uid
        }
    }

    var title: String {
        switch self {
        case .movement(let m): return [m.merchant ?? m.note, Formatting.money(m.amountMinor, m.currency)].compactMap { $0 }.joined(separator: " · ")
        case .account(let a): return a.name
        case .category(let c): return c.displayName
        case .reminder(let r): return r.name
        case .budget(let b): return b.name
        case .pot(let p): return p.name
        }
    }
}

struct RejectedRow: View {
    let change: RejectedChange
    let item: RejectedItem?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item?.title ?? L("rejected.missing")).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(verbatim: "\(RejectedText.entity(change.entity)) · \(RejectedText.reason(change))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Words for a refused change: what it is and why the server refused it.
enum RejectedText {
    private static let entities: Set<String> = ["transactions", "accounts", "categories", "reminders", "budgets", "pots"]
    private static let fields: Set<String> = ["merchant", "note", "name", "card", "amount_minor", "currency", "occurred_at", "kind",
                                              "category_ids", "day_of_month", "goal_minor", "goal_date", "key", "icon", "color", "raw_amount"]

    static func entity(_ entity: String) -> String {
        L(entities.contains(entity) ? "rejected.entity." + entity : "rejected.entity.other")
    }

    static func reason(_ change: RejectedChange) -> String {
        switch change.error {
        case "invalid_space": return L("rejected.reason.space")
        case "invalid_entity": return L("rejected.reason.entity")
        default:
            guard let field = change.field else { return L("rejected.reason.other") }
            let label = L(fields.contains(field) ? "rejected.field." + field : "rejected.field.other")
            return String(format: L("rejected.reason.field"), label)
        }
    }
}
