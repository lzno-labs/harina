// SPDX-License-Identifier: MPL-2.0
import BackgroundTasks
import HarinaKit
import LocalAuthentication
import Network
import SwiftData
import SwiftUI

@main
struct HarinaApp: App {
    static let refreshTask = "app.lzno.harina.sync"
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var lock = AppLock()
    @StateObject private var sync = SyncService.shared
    @AppStorage("onboarded") private var onboarded = false
    @State private var pendingLink: LinkRequest?
    @State private var badLink = false
    private let network = NetworkWatcher()

    var body: some Scene {
        WindowGroup {
            Group {
                if lock.locked {
                    LockedView(unlock: lock.unlock)
                } else if !onboarded {
                    OnboardingView { withAnimation { onboarded = true } }
                } else {
                    RootView()
                }
            }
            .environmentObject(sync)
            .onOpenURL { url in
                // harina://link?server=…&code=… from the web's QR code; always confirmed by the person.
                if let req = LinkRequest.parse(url) { pendingLink = req } else { badLink = true }
            }
            .sheet(item: $pendingLink) { LinkConfirmView(request: $0).environmentObject(sync) }
            .alert("deeplink.invalid", isPresented: $badLink) {}
            .onAppear {
                // Accounts and spaces (ADR-0006) started the server from scratch: the old link no longer
                // works, so it is dropped once and the person links or signs up again.
                if !AppSettings.defaults.bool(forKey: "spacesReset") {
                    SyncService.shared.unlink()
                    AppSettings.defaults.set(true, forKey: "spacesReset")
                }
                network.onReconnect = { Task { await SyncService.shared.sync() } }
                network.start()
            }
        }
        .modelContainer(Store.container)
        .onChange(of: phase) { _, new in
            switch new {
            case .active:
                lock.unlockIfNeeded()
                Task {
                    await sync.sync()
                    await Reminders.reschedule()
                }
            case .background:
                lock.lock()
                Self.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTask)) {
            Self.scheduleRefresh()
            await SyncService.shared.sync()
        }
    }

    /// Asks iOS to wake harina now and then to push payments captured offline.
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTask)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}

/// Face ID (or the passcode) when opening harina.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var locked = AppSettings.appLock
    private var authenticating = false

    func lock() { if AppSettings.appLock { locked = true } }

    func unlockIfNeeded() { if locked { unlock() } }

    func unlock() {
        guard !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false // no passcode set on the device: nothing to check against
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "lock.reason")) { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                if ok { self.locked = false }
            }
        }
    }
}

/// Syncs as soon as the connection comes back while harina is open.
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var wasOffline = false
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied, self.wasOffline { DispatchQueue.main.async { self.onReconnect?() } }
            self.wasOffline = path.status != .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "harina.network"))
    }
}
