// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import UIKit

/// Where the runs of «Registrar pago en Harina» are kept: this iPhone's settings, never synced and
/// never sent (docs/design/capture-log.md). The person can share a plain-text copy for support.
enum CaptureLog {
    private static let key = "captureLog"

    static var runs: [CaptureRun] {
        guard let data = AppSettings.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CaptureRun].self, from: data)) ?? []
    }

    private static func save(_ runs: [CaptureRun]) {
        AppSettings.defaults.set(try? JSONEncoder().encode(runs), forKey: key)
    }

    /// Written before anything else, so a run that iOS stops halfway still shows up.
    static func start(merchant: String?, amount: String?, card: String?) -> String {
        let run = CaptureRun(merchant: merchant, amountText: amount, card: card)
        save(CaptureLogRules.adding(run, to: runs))
        return run.id
    }

    static func update(_ id: String, _ change: (inout CaptureRun) -> Void) {
        save(CaptureLogRules.updating(id, in: runs, change))
    }

    static func clear() {
        AppSettings.defaults.removeObject(forKey: key)
    }

    /// A plain-text copy to send to support: the app and its settings, then one line per run.
    @MainActor
    static func report(_ runs: [CaptureRun], now: Date = Date()) -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let yes = L("capturelog.yes"), no = L("capturelog.no")
        let sync = SyncService.shared
        var lines = [
            "Harina \(version) · iOS \(UIDevice.current.systemVersion) · \(model())",
            String(format: L("capturelog.report.settings"),
                   sync.isLinked ? yes : no, AppSettings.autoCategory ? yes : no,
                   AppSettings.hostedDecider ? "\(yes) (\(Int((AppSettings.hostedThreshold * 100).rounded())) %)" : no),
            String(format: L("capturelog.report.lastSync"),
                   sync.lastSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-",
                   sync.lastError.map { String(describing: $0) } ?? "-"),
            "",
        ]
        for run in runs {
            var parts = [run.startedAt.formatted(date: .numeric, time: .standard),
                         run.merchant ?? "-", run.amountText ?? "-", run.card ?? "-", statusText(run, now: now)]
            if let d = run.duration { parts.append(String(format: "%.1f s", d)) }
            if let e = run.error { parts.append(e) }
            lines.append(parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    static func statusText(_ run: CaptureRun, now: Date) -> String {
        switch run.status(now: now) {
        case .running: return L("capturelog.status.running")
        case .saved:
            guard let source = run.categorySource else { return L(run.cutShort(now: now) ? "capturelog.status.savedCut" : "capturelog.status.saved") }
            return String(format: L("capturelog.status.savedAuto"), L("capturelog.source." + source))
        case .review: return L("capturelog.status.review")
        case .failed: return L("capturelog.status.failed")
        case .interrupted: return L("capturelog.status.interrupted")
        }
    }

    /// The hardware model, for example "iPhone15,2".
    private static func model() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
