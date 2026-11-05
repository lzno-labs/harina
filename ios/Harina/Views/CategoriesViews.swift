// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// Local category operations shared by onboarding and settings (docs/design/onboarding.md).
@MainActor
enum CategoryStore {
    /// First launch without a server: create the seven default suggestions with the server's ids
    /// and clock 0, not dirty, so a server copy (seeded or renamed on the web) wins when linking.
    static func ensureDefaults(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<CategoryItem>())) ?? 0
        guard count == 0 else { return }
        for s in CategoryCatalog.all where s.on {
            context.insert(CategoryItem(CategoryDTO(id: s.id, key: s.key, updated_at: 0), dirty: false))
        }
        try? context.save()
    }

    static func item(_ id: String, _ context: ModelContext) -> CategoryItem? {
        try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.id == id })).first
    }

    /// Turns a suggestion on or off. Off is a tombstone, so it syncs everywhere.
    static func toggle(_ s: SuggestedCategory, _ context: ModelContext) {
        if let c = item(s.id, context) {
            c.deleted.toggle()
            if !c.deleted { c.key = s.key }
            c.touch()
        } else {
            context.insert(CategoryItem(CategoryDTO(id: s.id, key: s.key, updated_at: SyncRules.now()), dirty: true))
        }
        try? context.save()
    }

    static func delete(_ c: CategoryItem, _ context: ModelContext) {
        c.deleted = true
        c.touch()
        try? context.save()
    }
}

/// Grid of suggestions and custom categories: tap to turn on or off, hold to edit.
struct CategoriesGrid: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: SyncService
    @Query private var all: [CategoryItem]
    @State private var editing: CategoryItem?
    @State private var creating = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    private var custom: [CategoryItem] {
        all.filter { !$0.deleted && CategoryCatalog.suggestion($0.key) == nil }.sorted { $0.displayName < $1.displayName }
    }

    private func active(_ s: SuggestedCategory) -> CategoryItem? {
        all.first { $0.id == s.id && !$0.deleted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(CategoryCatalog.all, id: \.key) { s in
                    let item = active(s)
                    cell(look: item.map { Looks.of($0) } ?? Looks.of(s),
                         name: item?.displayName ?? L("category." + s.key),
                         on: item != nil) {
                        withAnimation(.snappy) { CategoryStore.toggle(s, context) }
                        Task { await sync.sync() }
                    }
                    .contextMenu {
                        if let item {
                            Button { editing = item } label: { Label("categories.edit", systemImage: "pencil") }
                        }
                    }
                }
                ForEach(custom) { c in
                    cell(look: Looks.of(c), name: c.displayName, on: true) { editing = c }
                        .contextMenu {
                            Button { editing = c } label: { Label("categories.edit", systemImage: "pencil") }
                            Button(role: .destructive) { CategoryStore.delete(c, context) } label: { Label("form.delete", systemImage: "trash") }
                        }
                }
                Button { creating = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.title2.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text("categories.add").font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary))
                }
                .buttonStyle(.plain)
            }
            Text("categories.hint").font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { CategoryEditor(category: $0).environmentObject(sync) }
        .sheet(isPresented: $creating) { CategoryEditor(category: nil).environmentObject(sync) }
    }

    private func cell(look: CategoryLook, name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Tile(look: look, size: 44)
                    .saturation(on ? 1 : 0)
                    .opacity(on ? 1 : 0.45)
                Text(name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(on ? Color(hex: 0xFF6A4D) : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(on ? Color(hex: 0xFF6A4D) : Color.secondary)
                    .padding(7)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Name, emoji and color of a category, with a live preview. `category` nil creates one.
struct CategoryEditor: View {
    let category: CategoryItem?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: SyncService
    @State private var name = ""
    @State private var icon: String?
    @State private var color: String?
    @State private var customEmoji = ""
    @State private var confirmDelete = false

    private var preview: CategoryLook {
        Looks.make(id: category?.id ?? "new", key: category?.key, name: name.isEmpty ? "?" : name, icon: icon, color: color)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Tile(look: preview, size: 64)
                        TextField("categories.newName", text: $name)
                            .font(.title3.weight(.semibold))
                            .padding(13)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("categories.emoji").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                            ForEach(CategoryCatalog.emojis, id: \.self) { e in
                                Button { icon = e } label: {
                                    Text(verbatim: e).font(.title2).frame(width: 44, height: 44)
                                        .background(icon == e ? Color(hex: 0xFF6A4D).opacity(0.25) : Theme.fill,
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        TextField("categories.customEmoji", text: $customEmoji)
                            .padding(12)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: customEmoji) { _, new in
                                if let e = CategoryCatalog.firstEmoji(new) { icon = e }
                            }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("categories.color").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
                            ForEach(CategoryCatalog.colors, id: \.self) { c in
                                Button { color = c } label: {
                                    Circle().fill(Color(hex: CategoryCatalog.hex(c) ?? 0)).frame(width: 36, height: 36)
                                        .overlay { Circle().strokeBorder(color == c ? Color.primary : .clear, lineWidth: 3) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button(action: save) { Label("form.save", systemImage: "checkmark") }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if category != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("form.delete", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(LocalizedStringKey(category == nil ? "categories.add" : "categories.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("app.cancel") { dismiss() } }
            }
            .confirmationDialog("categories.confirmDeleteShort", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("form.delete", role: .destructive) {
                    if let category { CategoryStore.delete(category, context) }
                    Task { await sync.sync() }
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            name = category?.displayName ?? ""
            icon = category?.icon
            color = category?.color
        }
    }

    private func save() {
        let value = String(name.trimmingCharacters(in: .whitespaces).prefix(100))
        if let c = category {
            // A suggestion keeps following the language until the person really renames it.
            if !(c.key != nil && c.name == nil && value == c.displayName) { c.name = value }
            c.icon = icon
            c.color = color
            c.touch()
        } else {
            context.insert(CategoryItem(CategoryDTO(id: UUID().uuidString, name: value, icon: icon, color: color,
                                                    updated_at: SyncRules.now()), dirty: true))
        }
        try? context.save()
        Task { await sync.sync() }
        dismiss()
    }
}
