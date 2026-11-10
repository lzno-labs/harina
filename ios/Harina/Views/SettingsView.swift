// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI
import UIKit

/// Settings as a short list (docs/design/onboarding.md): the account on top, then one row per area
/// with its current state; the details live one tap away.
struct SettingsView: View {
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @Query(filter: #Predicate<AccountItem> { $0.deleted == false }) private var allAccounts: [AccountItem]
    @Query(filter: #Predicate<Movement> { $0.deleted == false }, sort: \Movement.occurredAt) private var movements: [Movement]
    @AppStorage("space") private var space = ""
    @AppStorage("appLock") private var appLock = true
    @AppStorage("autoCategory") private var autoCategory = true
    @Query(filter: #Predicate<BudgetItem> { $0.deleted == false }) private var budgets: [BudgetItem]
    @Query(filter: #Predicate<PotItem> { $0.deleted == false }) private var pots: [PotItem]
    @Query(filter: #Predicate<ReminderItem> { $0.deleted == false }) private var reminders: [ReminderItem]

    private var current: String { Spaces.valid(space) }
    private var categories: [CategoryItem] { allCategories.inSpace(current) }

    var body: some View {
        Form {
            Section {
                NavigationLink { AccountView() } label: { AccountCard() }
            }
            if sync.isLinked, sync.me?.hasPasskey == false {
                Section { PasskeyNudge() }
            }
            Section("settings.money") {
                if sync.isLinked {
                    row("spaces.title", "person.2.fill", [Color(hex: 0x22C58B), Color(hex: 0x0EA5A4)],
                        value: sync.spaces.map { Spaces.name(Spaces.local($0.id)) }.joined(separator: ", ")) { SpacesView() }
                }
                row("categories.title", "square.grid.2x2.fill", Theme.brandColors,
                    value: String(localized: "categories.count \(categories.count)")) {
                    ScrollView { CategoriesGrid().padding(16) }
                        .background(Theme.background)
                        .navigationTitle("categories.title")
                }
                row("accounts.title", "creditcard.fill", [Color(hex: 0x4C8DFF), Color(hex: 0x6A5CFF)],
                    value: "\(allAccounts.count)") { CardsView() }
                row("auto.title", "sparkles", [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)], value: autoSummary) {
                    Form { AutoCategorySection() }.navigationTitle("auto.title")
                }
                row("budgets.title", "tray.full.fill", [Color(hex: 0xA77BFF), Color(hex: 0xD061FF)],
                    value: "\(budgets.inSpace(current).count)") { BudgetsView() }
                row("pots.title", "banknote.fill", [Color(hex: 0x22D3EE), Color(hex: 0x0891B2)],
                    value: "\(pots.inSpace(current).count)") { PotsView() }
                row("reminders.title", "bell.fill", [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)],
                    value: "\(reminders.inSpace(current).count)") { RemindersView() }
            }
            Section("settings.capture") {
                row("settings.captureRow", "bolt.fill", [Color(hex: 0xFF5F6D), Color(hex: 0xFF4F6D)],
                    value: AppSettings.defaultCurrency) { CaptureSettingsView() }
                row("alerts.title", "bell.badge.fill", [Color(hex: 0x8B5CF6), Color(hex: 0x6366F1)],
                    value: String(format: "%02d:00", Reminders.hour)) { AlertsSettingsView() }
            }
            Section {
                Toggle(isOn: $appLock) {
                    Label { Text("settings.appLock") } icon: { IconTile(systemName: "faceid", colors: [Color(hex: 0x8B5CF6), Color(hex: 0x6366F1)], size: 30) }
                }
                ShareLink(item: exportFile()) {
                    Label { Text("settings.export") } icon: { IconTile(systemName: "square.and.arrow.up", colors: [Color(hex: 0x8E97A8), Color(hex: 0x5F6779)], size: 30) }
                }
                .foregroundStyle(.primary)
                if let terms = LegalLine.url("HarinaTermsURL"), let privacy = LegalLine.url("HarinaPrivacyURL") {
                    Link(destination: privacy) { Text("legal.privacyTitle") }
                    Link(destination: terms) { Text("legal.termsTitle") }
                }
            } header: {
                Text("settings.data")
            } footer: {
                Text("settings.privacy")
            }
            Section {
                Button("settings.replayOnboarding") { UserDefaults.standard.set(false, forKey: "onboarded") }
                    .font(.footnote)
            } footer: {
                Text(verbatim: "Harina \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            }
        }
        .navigationTitle("tab.settings")
        .tint(Color(hex: 0xFF4F6D))
    }

    private var autoSummary: String {
        guard autoCategory else { return L("settings.off") }
        let p = Smart.brain(movements: movements.inSpace(current), categories: categories).stats.precision
        return p.map { String(localized: "settings.autoValue \($0.formatted(.percent.precision(.fractionLength(0))))") } ?? L("settings.on")
    }

    private func row<Destination: View>(_ title: LocalizedStringKey, _ symbol: String, _ colors: [Color], value: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                IconTile(systemName: symbol, colors: colors, size: 30)
                Text(title)
                Spacer(minLength: 8)
                Text(verbatim: value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Everything on this iPhone as CSV (the web also exports JSON).
    private func exportFile() -> URL {
        let headers = ["date", "kind", "amount", "currency", "category", "account", "merchant", "note", "card", "source", "needs_review", "id"]
            .map { L("export." + $0) }
        let csv = CSVExport.make(
            movements.map(\.dto), headers: headers,
            categoryName: { id in allCategories.first { $0.id == id }?.displayName ?? "" },
            accountName: { id in allAccounts.first { $0.id == id }?.name ?? "" },
            label: { L("label." + $0) }
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "harina.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Top of settings: who you are, where your data lives and whether it is in sync.
struct AccountCard: View {
    @EnvironmentObject private var sync: SyncService

    private var me: SpaceInfo.Member? { sync.spaces.first?.members.first(where: \.me) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brand)
                Text(verbatim: String((me?.name ?? "H").prefix(1)).uppercased()).font(.title3.weight(.heavy)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                if sync.isLinked, let host = AppSettings.serverURL?.host() {
                    Text(verbatim: me?.name ?? host).font(.headline)
                    if sync.lastError != nil {
                        Label("settings.syncError", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    } else if let last = sync.lastSync {
                        Text("settings.syncedAt \(host) \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: host).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("settings.noAccount").font(.headline)
                    Text("settings.noAccountHint").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The account: sync, the web on the computer, linking and unlinking.
struct AccountView: View {
    @EnvironmentObject private var sync: SyncService
    @State private var confirmUnlink = false

    var body: some View {
        Form {
            if sync.isLinked, let url = AppSettings.serverURL {
                Section {
                    LabeledContent("settings.linkedTo") { Text(verbatim: url.host() ?? url.absoluteString) }
                    if let last = sync.lastSync {
                        LabeledContent("settings.lastSync") { Text(last.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    if sync.lastError != nil { Text("settings.syncError").foregroundStyle(.orange) }
                    Button("settings.syncNow") { Task { await sync.sync() } }.disabled(sync.syncing)
                }
                if sync.me?.hasPasskey == false {
                    Section { PasskeyNudge() }
                }
                Section {
                    NavigationLink("webcode.title") { WebCodeView() }
                } footer: {
                    Text("settings.webHint")
                }
                Section {
                    Button("settings.unlink", role: .destructive) { confirmUnlink = true }
                } footer: {
                    Text("settings.deleteHint")
                }
            } else {
                Section {
                    NavigationLink("settings.link") { LinkView() }
                } footer: {
                    Text("settings.linkHint")
                }
            }
        }
        .navigationTitle("settings.account")
        .confirmationDialog("settings.unlinkConfirm", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("settings.unlink", role: .destructive) { sync.unlink() }
        }
    }
}

/// Shown while the account has no passkey: today only this iPhone can open it, so deleting the app
/// or losing the phone would lock the person out (docs/adr/0007-passkeys-in-the-app.md).
struct PasskeyNudge: View {
    @EnvironmentObject private var sync: SyncService
    @Environment(\.authorizationController) private var authController
    @State private var working = false
    @State private var failed = false

    private var inApp: Bool { Passkeys.available(for: AppSettings.serverURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("passkey.warning.title").font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
            Text(inApp ? LocalizedStringKey("passkey.warning.text") : LocalizedStringKey("passkey.warning.textWeb")).font(.subheadline).foregroundStyle(.secondary)
            if failed { Text("passkey.createFailed").font(.footnote).foregroundStyle(.red) }
            if inApp {
                Button { Task { await create() } } label: {
                    if working { ProgressView().frame(maxWidth: .infinity) } else {
                        Label("passkey.create", systemImage: "person.badge.key.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working)
            } else {
                NavigationLink("webcode.title") { WebCodeView() }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private func create() async {
        working = true
        failed = false
        defer { working = false }
        do {
            try await Passkeys.create(controller: authController)
        } catch {
            failed = !Passkeys.cancelled(error)
        }
    }
}

/// Cards and accounts: each belongs to a space, where its Apple Pay payments land.
struct CardsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<AccountItem> { $0.deleted == false }, sort: \AccountItem.name) private var accounts: [AccountItem]
    @State private var adding = false
    @State private var newName = ""
    @State private var newCard = ""

    var body: some View {
        List {
            Section {
                ForEach(accounts) { a in
                    HStack(spacing: 12) {
                        IconTile(systemName: "creditcard.fill", colors: [Color(hex: 0x4C8DFF), Color(hex: 0x6A5CFF)], size: 32)
                        VStack(alignment: .leading) {
                            Text(verbatim: a.name)
                            if let card = a.card { Text(verbatim: card).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if sync.spaces.count > 1 {
                            Menu {
                                ForEach(sync.spaces.filter { Spaces.local($0.id) != a.space }) { sp in
                                    Button(Spaces.name(Spaces.local(sp.id))) { Task { try? await sync.move(a, to: Spaces.local(sp.id)) } }
                                }
                            } label: {
                                Label(Spaces.name(a.space), systemImage: "arrow.left.arrow.right").font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { accounts[i].deleted = true; accounts[i].updatedAt = SyncRules.now(); accounts[i].dirty = true }
                    saveAndSync()
                }
            } footer: {
                Text(accounts.isEmpty ? "accounts.empty" : "accounts.cardHint")
            }
        }
        .navigationTitle("accounts.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("accounts.add", systemImage: "plus") }
            }
        }
        .alert("accounts.add", isPresented: $adding) {
            TextField("accounts.name", text: $newName)
            TextField("accounts.card", text: $newCard)
            Button("spaces.save") { add() }
            Button("app.cancel", role: .cancel) { newName = ""; newCard = "" }
        } message: {
            Text("accounts.addHint")
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let card = newCard.trimmingCharacters(in: .whitespaces)
        context.insert(AccountItem(AccountDTO(id: UUID().uuidString, name: String(name.prefix(100)),
                                              card: card.isEmpty ? nil : String(card.prefix(100)), updated_at: SyncRules.now(),
                                              space_id: Spaces.wire(Spaces.current)), dirty: true))
        newName = ""; newCard = ""
        saveAndSync()
    }

    private func saveAndSync() {
        try? context.save()
        Task { await sync.sync() }
    }
}

/// Apple Pay capture: the shortcut guide, the category notification and the fallback currency.
struct CaptureSettingsView: View {
    @AppStorage("defaultCurrency") private var defaultCurrency = "CRC"
    @AppStorage("categoryNotifications") private var notify = true

    var body: some View {
        Form {
            Section {
                NavigationLink("settings.automationHelp") { AutomationHelpView() }
            }
            Section {
                Toggle("settings.notify", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        if on { Task { await PaymentNotifier.requestPermission() } }
                    }
                Picker("settings.defaultCurrency", selection: $defaultCurrency) {
                    Text(verbatim: "CRC").tag("CRC")
                    Text(verbatim: "USD").tag("USD")
                }
            }
        }
        .navigationTitle("settings.captureRow")
    }
}

struct LinkView: View {
    @EnvironmentObject private var sync: SyncService
    @Environment(\.dismiss) private var dismiss
    @State private var server = "https://"
    @State private var otherServer = LinkView.defaultServer == nil
    @State private var code = ""
    @State private var working = false
    @State private var failed: LocalizedStringKey?
    @Environment(\.authorizationController) private var authController

    /// The server this build offers by default (Info.plist `HarinaDefaultServer`), if any.
    static var defaultServer: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "HarinaDefaultServer") as? String,
              text.hasPrefix("https://"), let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                if let preset = Self.defaultServer, !otherServer {
                    LabeledContent("link.serverLabel") { Text(verbatim: preset.host() ?? preset.absoluteString) }
                } else {
                    TextField("link.server", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField("link.code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            } footer: {
                Text("link.help")
            }
            if Self.defaultServer != nil {
                Section {
                    Toggle("link.useOther", isOn: $otherServer)
                } footer: {
                    Text("link.otherHelp")
                }
            }
            Button("link.button") { Task { await link() } }.disabled(working || code.count < 8)
            if let url = chosenServer, Passkeys.available(for: url) {
                Section {
                    Button { Task { await passkeySignIn(url) } } label: {
                        Label("passkey.signIn", systemImage: "person.badge.key.fill")
                    }
                    .disabled(working)
                } footer: {
                    Text("passkey.signInHint")
                }
            }
            Section {
                Button("signup.button") { Task { await signUp() } }.disabled(working)
            } header: {
                Text("signup.header")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("signup.footer")
                    LegalLine()
                }
            }
            if let failed { Text(failed).foregroundStyle(.red) }
        }
        .navigationTitle("settings.link")
    }

    private var chosenServer: URL? {
        let url = !otherServer ? Self.defaultServer : URL(string: server.trimmingCharacters(in: .whitespaces))
        guard let url, url.scheme == "https" || url.host() == "localhost" else { return nil }
        return url
    }

    private func passkeySignIn(_ url: URL) async {
        working = true
        failed = nil
        defer { working = false }
        do {
            try await Passkeys.signIn(server: url, controller: authController)
            dismiss()
        } catch {
            if !Passkeys.cancelled(error) { failed = "passkey.failed" }
        }
    }

    private func signUp() async {
        guard let url = chosenServer else {
            failed = "link.badServer"
            return
        }
        working = true
        defer { working = false }
        do {
            try await sync.signUp(server: url, deviceName: UIDevice.current.name)
            await sync.sync()
            dismiss()
        } catch SyncError.signupClosed {
            failed = "signup.closed"
        } catch {
            failed = "link.failed"
        }
    }

    private func link() async {
        guard let url = chosenServer else {
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

/// A one-time code to open this account on the web, where the person adds a passkey
/// (docs/design/people-and-spaces.md).
struct WebCodeView: View {
    @EnvironmentObject private var sync: SyncService
    @State private var code: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                if let code {
                    Text(verbatim: code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                } else if failed {
                    Text("webcode.failed").foregroundStyle(.red)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } footer: {
                if let host = AppSettings.serverURL?.host() {
                    Text("webcode.help \(host)")
                }
            }
            Button("webcode.new") { Task { await load() } }
        }
        .navigationTitle("webcode.title")
        .task { await load() }
    }

    private func load() async {
        failed = false
        code = nil
        do { code = try await sync.webCode() } catch { failed = true }
    }
}

