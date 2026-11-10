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

    /// Where the person keeps their data: only on this iPhone, or also on a server (docs/design/onboarding.md).
    private enum Storage { case local, server }

    private let steps = 6

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
                categoriesStep.tag(2)
                captureStep.tag(3)
                faceIDStep.tag(4)
                linkStep.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy, value: step)
        }
        .background(Theme.background)
        .onAppear { CategoryStore.ensureDefaults(context) }
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
            }
        } actions: {
            Button("onboarding.start", action: next).buttonStyle(BrandButtonStyle())
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

    private var categoriesStep: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                title("onboarding.categories.title", "onboarding.categories.text")
                CategoriesGrid()
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

    private var faceIDStep: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "faceid").font(.system(size: 56, weight: .semibold)).foregroundStyle(Theme.brand)
                title("onboarding.faceid.title", "onboarding.faceid.text")
            }
        } actions: {
            Button {
                let ctx = LAContext()
                var error: NSError?
                guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return next() }
                ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("lock.reason")) { ok, _ in
                    Task { @MainActor in
                        if ok { AppSettings.appLock = true }
                        next()
                    }
                }
            } label: { Label("onboarding.faceid.enable", systemImage: "faceid") }
            .buttonStyle(BrandButtonStyle())
            Button("onboarding.notNow", action: next).font(.subheadline.weight(.semibold))
        }
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
                        if let signupError { Text(signupError).font(.footnote).foregroundStyle(.red) }
                        Text("onboarding.link.haveAccount").font(.subheadline.weight(.semibold))
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
    @Query(filter: #Predicate<CategoryItem> { $0.deleted == false }) private var categories: [CategoryItem]

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
