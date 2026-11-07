// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]
    @Query(filter: #Predicate<AccountItem> { $0.deleted == false }) private var accounts: [AccountItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt) private var movements: [Movement]
    @AppStorage("defaultCurrency") private var defaultCurrency = "CRC"
    @AppStorage("appLock") private var appLock = true
    @AppStorage("categoryNotifications") private var notify = true
    @State private var newAccount = ""
    @State private var newCard = ""

    var body: some View {
        Form {
            Section("settings.server") {
                if sync.isLinked, let url = AppSettings.serverURL {
                    LabeledContent("settings.linkedTo") { Text(url.host() ?? url.absoluteString) }
                    if let last = sync.lastSync {
                        LabeledContent("settings.lastSync") { Text(last.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    if sync.lastError != nil { Text("settings.syncError").foregroundStyle(.orange) }
                    Button("settings.syncNow") { Task { await sync.sync() } }.disabled(sync.syncing)
                    Button("settings.unlink", role: .destructive) { sync.unlink() }
                } else {
                    NavigationLink("settings.link") { LinkView() }
                    Text("settings.linkHint").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("settings.capture") {
                NavigationLink("settings.automationHelp") { AutomationHelpView() }
                Toggle("settings.notify", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        if on { Task { await PaymentNotifier.requestPermission() } }
                    }
                Picker("settings.defaultCurrency", selection: $defaultCurrency) {
                    Text(verbatim: "CRC").tag("CRC")
                    Text(verbatim: "USD").tag("USD")
                }
            }
            Section("categories.title") {
                NavigationLink {
                    ScrollView { CategoriesGrid().padding(16) }
                        .background(Theme.background)
                        .navigationTitle("categories.title")
                } label: {
                    HStack(spacing: 12) {
                        IconTile(systemName: "square.grid.2x2.fill", colors: Theme.brandColors, size: 32)
                        VStack(alignment: .leading) {
                            Text("categories.manage")
                            Text("categories.count \(categories.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            AutoCategorySection()
            Section {
                ForEach(accounts) { a in
                    HStack(spacing: 12) {
                        IconTile(systemName: "creditcard.fill", colors: [Color(hex: 0x4C8DFF), Color(hex: 0x6A5CFF)], size: 32)
                        VStack(alignment: .leading) {
                            Text(a.name)
                            if let card = a.card { Text(card).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { accounts[i].deleted = true; accounts[i].updatedAt = SyncRules.now(); accounts[i].dirty = true }
                    saveAndSync()
                }
                TextField("accounts.name", text: $newAccount)
                TextField("accounts.card", text: $newCard)
                Button("accounts.add") {
                    let name = newAccount.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let card = newCard.trimmingCharacters(in: .whitespaces)
                    context.insert(AccountItem(AccountDTO(id: UUID().uuidString, name: String(name.prefix(100)),
                                                          card: card.isEmpty ? nil : String(card.prefix(100)), updated_at: SyncRules.now()), dirty: true))
                    newAccount = ""; newCard = ""
                    saveAndSync()
                }
            } header: {
                Text("accounts.title")
            } footer: {
                Text("accounts.cardHint")
            }
            Section {
                ShareLink(item: exportFile()) { Label("settings.export", systemImage: "square.and.arrow.up") }
                Toggle("settings.appLock", isOn: $appLock)
                Button("settings.replayOnboarding") { UserDefaults.standard.set(false, forKey: "onboarded") }
            } header: {
                Text("settings.data")
            } footer: {
                Text("settings.privacy")
            }
        }
        .navigationTitle("tab.settings")
        .tint(Color(hex: 0xFF4F6D))
    }

    private func saveAndSync() {
        try? context.save()
        Task { await sync.sync() }
    }

    /// Everything on this iPhone as CSV (the web also exports JSON).
    private func exportFile() -> URL {
        let headers = ["date", "kind", "amount", "currency", "category", "account", "merchant", "note", "card", "source", "needs_review", "id"]
            .map { L("export." + $0) }
        let csv = CSVExport.make(
            movements.map(\.dto), headers: headers,
            categoryName: { id in categories.first { $0.id == id }?.displayName ?? "" },
            accountName: { id in accounts.first { $0.id == id }?.name ?? "" },
            label: { L("label." + $0) }
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "harina.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct LinkView: View {
    @EnvironmentObject private var sync: SyncService
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://"
    @State private var code = ""
    @State private var working = false
    @State private var failed: LocalizedStringKey?

    var body: some View {
        Form {
            Section {
                TextField("link.server", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("link.code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            } footer: {
                Text("link.help")
            }
            Button("link.button") { Task { await link() } }.disabled(working || code.count < 8)
            if let failed { Text(failed).foregroundStyle(.red) }
        }
        .navigationTitle("settings.link")
    }

    private func link() async {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.host() == "localhost" else {
            failed = "link.badServer"
            return
        }
        working = true
        defer { working = false }
        do {
            try await sync.link(server: url, code: code, deviceName: UIDevice.current.name)
            await sync.sync()
            dismiss()
        } catch SyncError.invalidLinkCode {
            failed = "link.badCode"
        } catch {
            failed = "link.failed"
        }
    }
}

/// One-step guide to create the "Transaction" automation that runs our App Intent.
struct AutomationHelpView: View {
    var body: some View {
        List {
            Section {
                ForEach(Array(AutomationGuide.stepKeys(short: false).enumerated()), id: \.offset) { item in
                    let text = L(item.element)
                    // The manual steps carry their number; the shorter ones get it here.
                    Text(verbatim: text.first?.isNumber == true ? text : "\(item.offset + 1). \(text)")
                }
            } footer: {
                Text("automation.footer")
            }
            Section {
                Button { AutomationGuide.open() } label: {
                    Label(LocalizedStringKey(AutomationGuide.shortcutURL == nil ? "automation.open" : "automation.add"), systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("settings.automationHelp")
    }
}
