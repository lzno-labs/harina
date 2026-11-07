// SPDX-License-Identifier: MPL-2.0
import AppIntents
import Foundation
import HarinaKit
import SwiftData

/// "Oye Siri, anota un gasto en harina" (docs/design/siri-y-notificaciones.md): for payments with no
/// automatic signal (SINPE Móvil, cash, transfers). Saves on the iPhone first, so it works offline.
struct AddMovementIntent: AppIntent {
    static let title: LocalizedStringResource = "siri.title"
    static let description = IntentDescription("siri.description")
    static let openAppWhenRun = false

    @Parameter(title: "siri.param.amount", requestValueDialog: IntentDialog("siri.ask.amount"))
    var amount: Double

    @Parameter(title: "siri.param.concept", requestValueDialog: IntentDialog("siri.ask.concept"))
    var concept: String

    @Parameter(title: "siri.param.kind", default: .expense)
    var kind: MovementKind

    @Parameter(title: "siri.param.currency")
    var currency: MovementCurrency?

    @Parameter(title: "siri.param.category")
    var category: CategoryEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let cur = currency?.rawValue ?? AppSettings.defaultCurrency
        let scale = pow(10.0, Double(Money.minorUnits(cur)))
        let minor = Int64((amount * scale).rounded())
        guard minor > 0 else { throw $amount.needsValueError(IntentDialog("siri.ask.amount")) }

        let context = Store.container.mainContext
        var dto = TransactionDTO(
            id: UUID().uuidString, kind: kind.rawValue, amount_minor: minor, currency: cur,
            category_id: category?.id, merchant: String(concept.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            source: "manual", occurred_at: ISODate.string(Date()), updated_at: SyncRules.now()
        )
        let brain = Smart.brain(context)
        // Without a spoken category, the decision model categorizes only when it is sure.
        if dto.category_id == nil, kind == .expense, AppSettings.autoCategory {
            let d = brain.model.decide(brain.calibration, DecisionState(dto))
            if d.band == .act, let id = d.categoryId { dto.category_id = id; dto.category_auto = 1 }
        }
        context.insert(Movement(dto, dirty: true))
        try context.save()
        await SyncService.shared.sync()

        let money = Formatting.money(minor, cur)
        let name = brain.category(dto.category_id)?.displayName
        let text = name.map { String(localized: "siri.done.category \(money) \(dto.merchant ?? "") \($0)") }
            ?? String(localized: "siri.done \(money) \(dto.merchant ?? "")")
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

enum MovementKind: String, AppEnum {
    case expense, income
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "siri.kind.type"
    static let caseDisplayRepresentations: [MovementKind: DisplayRepresentation] = [
        .expense: "siri.kind.expense",
        .income: "siri.kind.income",
    ]
}

enum MovementCurrency: String, AppEnum {
    case CRC, USD
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "siri.currency.type"
    static let caseDisplayRepresentations: [MovementCurrency: DisplayRepresentation] = [
        .CRC: "siri.currency.CRC",
        .USD: "siri.currency.USD",
    ]
}

/// A category Siri can match by name ("en comida").
struct CategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "siri.category.type"
    static let defaultQuery = CategoryQuery()

    let id: String
    let name: String
    let glyph: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(glyph) \(name)")
    }
}

struct CategoryQuery: EntityStringQuery {
    @MainActor
    private func all() -> [CategoryEntity] {
        let items = (try? Store.container.mainContext.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.deleted == false }))) ?? []
        return items.map { CategoryEntity(id: $0.id, name: $0.displayName, glyph: Looks.of($0).glyph) }
            .sorted { $0.name < $1.name }
    }

    func entities(for identifiers: [String]) async throws -> [CategoryEntity] {
        await MainActor.run { all().filter { identifiers.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [CategoryEntity] {
        let key = MerchantKey.normalize(string)
        return await MainActor.run { all().filter { MerchantKey.normalize($0.name).contains(key) } }
    }

    func suggestedEntities() async throws -> [CategoryEntity] {
        await MainActor.run { all() }
    }
}
