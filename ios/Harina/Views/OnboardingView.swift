// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit

/// iPhone-first onboarding (docs/design/onboarding.md): value first, permissions last,
/// everything optional can be skipped.
struct OnboardingView: View {
    let finish: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<Movement> { $0.source == "apple_pay" && $0.deleted == false }) private var captured: [Movement]
    @AppStorage("defaultCurrency") private var currency = "CRC"
    @State private var step = 0
    @State private var openedShortcuts = false
    @State private var showLinkForm = false
    @State private var storage: Storage?
    @State private var signingUp = false
    @State private var signupError: LocalizedStringKey?
    @State private var alertsAllowed = false
    @State private var bills = Set<String>()
    @State private var billDays: [String: Int] = [:]
    @AppStorage("appLock") private var appLock = false
    @Environment(\.authorizationController) private var authController
    /// An account left in the Keychain by an earlier install of the app on this iPhone (ADR-0007).
    @State private var restorable: SyncService.Restorable?

    /// Where the person keeps their data: only on this iPhone, or also on a server (docs/design/onboarding.md).
    private enum Storage { case local, server }

    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i <= step ? AnyShapeStyle(Theme.brandHorizontal) : AnyShapeStyle(Theme.fill)).frame(height: 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TabView(selection: $step) {
                welcome.tag(0)
                currencyStep.tag(1)
                captureStep.tag(2)
                alertsStep.tag(3)
                linkStep.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Theme.background)
        .onAppear { CategoryStore.ensureDefaults(context) }
        .task { restorable = await sync.restorable() }
        .sheet(isPresented: $showLinkForm) { NavigationStack { LinkView() }.environmentObject(sync) }
    }

    private func next() { withAnimation(.snappy) { step = min(step + 1, steps - 1) } }

    // MARK: steps

    private var welcome: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("onboarding.welcome.title").font(.largeTitle.weight(.heavy)).tracking(-0.8)
                Text("onboarding.welcome.text").font(.title3).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    feature("bolt.fill", [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)], "onboarding.welcome.f1")
                    feature("dollarsign.arrow.circlepath", [Color(hex: 0x22C58B), Color(hex: 0x0EA5A4)], "onboarding.welcome.f2")
                    feature("lock.shield.fill", [Color(hex: 0x8B5CF6), Color(hex: 0x6366F1)], "onboarding.welcome.f3")
                }
                .padding(.top, 8)
                if let restorable {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("restore.title", systemImage: "checkmark.icloud.fill").font(.headline)
                        Text("restore.text \(restorable.server.host() ?? restorable.server.absoluteString)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                }
            }
        } actions: {
            if let restorable {
                Button {
                    sync.restore(restorable)
                    Task { await sync.sync() }
                    done()
                } label: {
                    if let name = restorable.name, !name.isEmpty { Text("restore.continueAs \(name)") } else { Text("restore.continue") }
                }
                .buttonStyle(BrandButtonStyle())
                Button("restore.fresh", action: next).font(.subheadline.weight(.semibold))
            } else {
                Button("onboarding.start", action: next).buttonStyle(BrandButtonStyle())
            }
        }
    }

    private var currencyStep: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                title("onboarding.currency.title", "onboarding.currency.text")
                ForEach(["CRC", "USD"], id: \.self) { c in
                    Button { currency = c } label: {
                        HStack(spacing: 14) {
                            Text(verbatim: c == "CRC" ? "₡" : "$")
                                .font(.title.weight(.heavy)).foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(c == "CRC" ? Theme.brand : LinearGradient(colors: [Color(hex: 0x22C58B), Color(hex: 0x0EA5A4)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            VStack(alignment: .leading) {
                                Text(LocalizedStringKey("onboarding.currency." + c)).font(.headline)
                                Text(verbatim: Formatting.money(450_000, c)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            Image(systemName: currency == c ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(currency == c ? Color(hex: 0xFF6A4D) : Color.secondary)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                }
            }
        } actions: {
            Button("onboarding.continue", action: next).buttonStyle(BrandButtonStyle())
        }
    }

    private var captureStep: some View {
        page {
            VStack(alignment: .leading, spacing: 16) {
                title("onboarding.capture.title", "onboarding.capture.text")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AutomationGuide.stepKeys(short: true).enumerated()), id: \.offset) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: "\(item.offset + 1)").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(Theme.brand, in: Circle())
                            Text(L(item.element)).font(.subheadline)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .card()
                if let first = captured.first {
                    Label {
                        Text("onboarding.capture.works \(Formatting.money(first.amountMinor, first.currency))")
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.earn) }
                    .font(.headline)
                    .card()
                } else if openedShortcuts {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("onboarding.capture.waiting").font(.subheadline.weight(.semibold))
                    }
                    .card()
                }
            }
        } actions: {
            if captured.isEmpty {
                Button {
                    openedShortcuts = true
                    Task {
                        // Permission for the "pick a category" notification after each payment.
                        await PaymentNotifier.requestPermission()
                        AutomationGuide.open()
                    }
                } label: {
                    Label(LocalizedStringKey(AutomationGuide.shortcutURL == nil ? "automation.open" : "automation.add"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(BrandButtonStyle())
                Button("onboarding.later", action: next).font(.subheadline.weight(.semibold))
            } else {
                Button("onboarding.continue", action: next).buttonStyle(BrandButtonStyle())
            }
        }
    }

    /// One permission for every alert, explained by what it brings, and the monthly payments Harina
    /// cannot see turned into reminders with one tap each (docs/design/onboarding.md).
    private var alertsStep: some View {
        page {
            VStack(alignment: .leading, spacing: 16) {
                title("onboarding.alerts.title", "onboarding.alerts.text")
                VStack(spacing: 10) {
                    feature("hand.tap.fill", [Color(hex: 0xFF5F6D), Color(hex: 0xFF4F6D)], "onboarding.alerts.f1")
                    feature("calendar.badge.clock", [Color(hex: 0x8B5CF6), Color(hex: 0x6366F1)], "onboarding.alerts.f2")
                    feature("bell.fill", [Color(hex: 0xFFB547), Color(hex: 0xFF7A45)], "onboarding.alerts.f3")
                }
                if alertsAllowed {
                    Label("onboarding.alerts.on", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.earn)
                } else {
                    Button { Task { alertsAllowed = await PaymentNotifier.requestPermission() } } label: {
                        Label("onboarding.alerts.allow", systemImage: "bell.badge")
                    }
                    .buttonStyle(ChipStyle())
                }
                Text("onboarding.bills.title").font(.headline).padding(.top, 6)
                Text("onboarding.bills.text").font(.subheadline).foregroundStyle(.secondary)
                FlowChips(items: Self.bills.map { ($0, L("onboarding.bills." + $0)) }, selected: $bills)
                ForEach(Self.bills.filter { bills.contains($0) }, id: \.self) { key in
                    Stepper(value: Binding(get: { billDays[key] ?? 15 }, set: { billDays[key] = $0 }), in: 1...31) {
                        Text("onboarding.bills.day \(L("onboarding.bills." + key)) \(billDays[key] ?? 15)").font(.subheadline)
                    }
                }
            }
        } actions: {
            Button("onboarding.continue") {
                saveBills()
                next()
            }
            .buttonStyle(BrandButtonStyle())
        }
        .task { alertsAllowed = await PaymentNotifier.authorized() }
    }

    static let bills = ["card", "power", "water", "internet", "rent", "phone"]

    /// Each chosen bill becomes a monthly reminder in the personal space.
    private func saveBills() {
        for key in Self.bills where bills.contains(key) {
            context.insert(ReminderItem(ReminderDTO(id: UUID().uuidString, name: L("onboarding.bills." + key), day_of_month: billDays[key] ?? 15,
                                                    updated_at: SyncRules.now()), dirty: true))
        }
        bills = []
        try? context.save()
    }

    private var linkStep: some View {
        page {
            VStack(alignment: .leading, spacing: 16) {
                title("onboarding.storage.title", "onboarding.storage.text")
                if sync.isLinked, let url = AppSettings.serverURL {
                    Label {
                        Text("onboarding.link.done \(url.host() ?? url.absoluteString)")
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.earn) }
                    .font(.headline)
                    .card()
                } else {
                    storageOption(.local, systemImage: "iphone", title: "onboarding.storage.local",
                                  pros: ["onboarding.storage.local.pro1", "onboarding.storage.local.pro2"],
                                  cons: ["onboarding.storage.local.con1", "onboarding.storage.local.con2"]
                                      + (AppleIntelligence.status == .available ? [] : ["onboarding.storage.local.con3"]))
                    storageOption(.server, systemImage: "externaldrive.connected.to.line.below", title: serverTitle,
                                  pros: ["onboarding.storage.server.pro1", "onboarding.storage.server.pro2", "onboarding.storage.server.pro3"]
                                      + (AppleIntelligence.status == .available ? [] : ["onboarding.storage.server.pro4"]),
                                  cons: ["onboarding.storage.server.con1", "onboarding.storage.server.con2"])
                    if storage == .server {
                        LegalLine()
                        if let signupError { Text(signupError).font(.footnote).foregroundStyle(.red) }
                        Text("onboarding.link.haveAccount").font(.subheadline.weight(.semibold))
                        if let server = LinkView.defaultServer, Passkeys.available(for: server) {
                            Button { Task { await passkeySignIn(server) } } label: {
                                Label("passkey.signIn", systemImage: "person.badge.key.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(signingUp)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            if let host = LinkView.defaultServer?.host() {
                                Label("onboarding.link.qr1.host \(host)", systemImage: "desktopcomputer")
                            } else {
                                Label("onboarding.link.qr1", systemImage: "desktopcomputer")
                            }
                            Label("onboarding.link.qr2", systemImage: "qrcode.viewfinder")
                            Label("onboarding.link.qr3", systemImage: "checkmark.seal")
                        }
                        .font(.subheadline)
                        .card()
                        Button("onboarding.link.manual") { showLinkForm = true }.font(.subheadline.weight(.semibold))
                    }
                    Text("onboarding.storage.later").font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { appLock }, set: { on in if on { enableFaceID() } else { appLock = false } })) {
                    Label("onboarding.faceid.toggle", systemImage: "faceid")
                }
                .card()
            }
        } actions: {
            if sync.isLinked {
                Button("onboarding.finish", action: done).buttonStyle(BrandButtonStyle())
            } else {
                switch storage {
                case .local: Button("onboarding.storage.startLocal", action: done).buttonStyle(BrandButtonStyle())
                case .server:
                    if let host = LinkView.defaultServer?.host() {
                        Button { Task { await signUp() } } label: {
                            if signingUp { ProgressView().tint(.white) } else { Text("onboarding.signup.button \(host)") }
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(signingUp)
                        Button("onboarding.link.later", action: done).font(.subheadline.weight(.semibold))
                    } else {
                        Button("onboarding.link.later", action: done).buttonStyle(BrandButtonStyle())
                    }
                case nil: Button("onboarding.storage.choose") {}.buttonStyle(BrandButtonStyle()).disabled(true).opacity(0.5)
                }
            }
        }
    }

    /// Creates the account on the default server with this iPhone (docs/design/people-and-spaces.md).
    private func signUp() async {
        guard let server = LinkView.defaultServer else { return }
        signingUp = true
        signupError = nil
        defer { signingUp = false }
        do {
            try await sync.signUp(server: server, deviceName: UIDevice.current.name)
            await sync.sync()
        } catch SyncError.signupClosed {
            signupError = "signup.closed"
        } catch {
            signupError = "link.failed"
        }
    }

    /// Signs in with a passkey of an existing account, for example after reinstalling (ADR-0007).
    private func passkeySignIn(_ server: URL) async {
        signingUp = true
        signupError = nil
        defer { signingUp = false }
        do {
            try await Passkeys.signIn(server: server, controller: authController)
        } catch {
            if !Passkeys.cancelled(error) { signupError = "passkey.failed" }
        }
    }

    private var serverTitle: LocalizedStringKey {
        if let host = LinkView.defaultServer?.host() { return "onboarding.storage.server.host \(host)" }
        return "onboarding.storage.server"
    }

    private func storageOption(_ option: Storage, systemImage symbol: String, title: LocalizedStringKey,
                               pros: [LocalizedStringKey], cons: [LocalizedStringKey]) -> some View {
        let selected = storage == option
        return Button { withAnimation(.snappy) { storage = option } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 28)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary))
                }
                ForEach(Array(pros.enumerated()), id: \.offset) { _, text in
                    Label { Text(text) } icon: { Image(systemName: "checkmark").foregroundStyle(Theme.earn) }
                }
                ForEach(Array(cons.enumerated()), id: \.offset) { _, text in
                    Label { Text(text) } icon: { Image(systemName: "minus").foregroundStyle(Theme.warn) }
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.clear), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func enableFaceID() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("lock.reason")) { ok, _ in
            Task { @MainActor in appLock = ok }
        }
    }

    private func done() {
        AppSettings.onboarded = true
        AppSettings.onboardedAt = Date()
        finish()
    }

    // MARK: building blocks

    private func page<Content: View, Actions: View>(@ViewBuilder _ content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
            }
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    private func title(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.heavy)).tracking(-0.8)
            Text(text).font(.body).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ colors: [Color], _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            IconTile(systemName: symbol, colors: colors, size: 40)
            Text(text).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .card()
    }
}

// MARK: - QR deep link

/// Confirms a `harina://link` before linking: the person sees which server receives their data.
struct LinkConfirmView: View {
    let request: LinkRequest
    @EnvironmentObject private var sync: SyncService
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var failed: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 18) {
            IconTile(systemName: "link", colors: Theme.brandColors, size: 64)
                .padding(.top, 28)
            Text("deeplink.title").font(.title2.weight(.heavy))
            Text(verbatim: request.server.host() ?? request.server.absoluteString)
                .font(.title3.weight(.bold)).foregroundStyle(Color(hex: 0xFF4F6D))
            Text("deeplink.text").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if sync.isLinked, let current = AppSettings.serverURL {
                Text("deeplink.replace \(current.host() ?? current.absoluteString)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
            }
            if let failed { Text(failed).font(.footnote.weight(.semibold)).foregroundStyle(Theme.spend) }
            Spacer()
            Button {
                Task { await link() }
            } label: {
                if working { ProgressView().tint(.white) } else { Label("deeplink.confirm", systemImage: "checkmark") }
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(working)
            Button("app.cancel") { dismiss() }.font(.subheadline.weight(.semibold))
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func link() async {
        working = true
        defer { working = false }
        do {
            if sync.isLinked { sync.unlink() }
            try await sync.link(server: request.server, code: request.code, deviceName: UIDevice.current.name)
            await sync.sync()
            dismiss()
        } catch SyncError.invalidLinkCode {
            failed = "link.badCode"
        } catch {
            failed = "link.failed"
        }
    }
}

// MARK: - First payment and first week

/// Shown once, when the first Apple Pay payment arrives: proof that the automation works.
struct FirstCaptureView: View {
    let movement: Movement
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sync: SyncService
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var allCategories: [CategoryItem]
    @AppStorage("space") private var spaceC = ""
    private var categories: [CategoryItem] { allCategories.inSpace(Spaces.valid(spaceC)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(verbatim: "🎉").font(.system(size: 64)).padding(.top, 24)
                Text("firstcapture.title").font(.largeTitle.weight(.heavy))
                Text(verbatim: movement.needsReview ? (movement.rawAmount ?? "") : Formatting.money(movement.amountMinor, movement.currency))
                    .font(.system(size: 40, weight: .heavy)).monospacedDigit()
                if let m = movement.merchant { Text(verbatim: m).font(.headline).foregroundStyle(.secondary) }
                Text("firstcapture.text").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(categories.sorted { $0.displayName < $1.displayName }) { c in
                        Button {
                            movement.setCategory(byPerson: c.id)
                            movement.touch()
                            try? context.save()
                            Task { await sync.sync() }
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Tile(look: Looks.of(c), size: 40)
                                Text(c.displayName).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("onboarding.later") { dismiss() }.font(.subheadline.weight(.semibold)).padding(.top, 6)
            }
            .padding(20)
        }
        .background(Theme.background)
    }
}

/// The PRD's first-week checks, ticked from real data (Apple Watch needs the person's answer).
struct FirstWeekCard: View {
    @Query(filter: #Predicate<Movement> { $0.source == "apple_pay" && $0.deleted == false }) private var captured: [Movement]
    @AppStorage("watchCheck") private var watchCheck = ""
    @AppStorage("firstWeekHidden") private var hidden = false
    @EnvironmentObject private var sync: SyncService

    private var offline: (done: Bool, waiting: Bool) {
        guard let id = AppSettings.offlineCaptureId, let m = captured.first(where: { $0.id == id }) else { return (false, false) }
        return (!m.dirty, m.dirty)
    }

    private var visible: Bool {
        guard !hidden, let start = AppSettings.onboardedAt else { return false }
        let allDone = !captured.isEmpty && watchCheck == "yes" && offline.done
        return !allDone && Date().timeIntervalSince(start) < 14 * 86_400
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("firstweek.title").font(.headline)
                    Spacer()
                    Button("firstweek.hide") { withAnimation { hidden = true } }.font(.subheadline.weight(.semibold))
                }
                item(done: !captured.isEmpty, "firstweek.iphone", "firstweek.iphone.text")
                VStack(alignment: .leading, spacing: 8) {
                    item(done: watchCheck == "yes", "firstweek.watch", watchCheck == "no" ? "firstweek.watch.no" : "firstweek.watch.text")
                    if watchCheck.isEmpty {
                        HStack {
                            Button("firstweek.watch.yes") { watchCheck = "yes" }.buttonStyle(ChipStyle())
                            Button("firstweek.watch.notYet") { watchCheck = "no" }.buttonStyle(ChipStyle())
                        }
                        .padding(.leading, 40)
                    }
                }
                item(done: offline.done, "firstweek.offline",
                     offline.waiting ? "firstweek.offline.waiting" : sync.isLinked ? "firstweek.offline.text" : "firstweek.offline.link")
            }
            .card()
        }
    }

    private func item(done: Bool, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(done ? Theme.earn : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).strikethrough(done).foregroundStyle(done ? Color.secondary : Color.primary)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Chips that wrap onto several lines; tap to select or unselect.
struct FlowChips: View {
    let items: [(key: String, label: String)]
    @Binding var selected: Set<String>

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.key) { item in
                let on = selected.contains(item.key)
                Button {
                    if on { selected.remove(item.key) } else { selected.insert(item.key) }
                } label: {
                    Label(item.label, systemImage: on ? "checkmark" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.fill), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Places views left to right, wrapping to the next line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

