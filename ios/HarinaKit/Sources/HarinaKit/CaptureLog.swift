// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One run of «Registrar pago en Harina», kept only on this iPhone so a missing payment can be
/// traced (docs/design/capture-log.md). It is never synced or sent anywhere.
public struct CaptureRun: Codable, Equatable, Sendable, Identifiable {
    public enum Step: String, Codable, Sendable {
        /// Started: the payment is not saved yet.
        case started
        /// Saved on the iPhone; syncing and notifications may still be running.
        case saved
        /// Finished.
        case done
        /// Stopped by an error before the payment was saved.
        case failed
    }

    public enum Status: String, Sendable {
        case running, saved, review, failed
        /// Never finished and never saved: iOS stopped the run or the app closed.
        case interrupted
    }

    /// iOS gives an automation little time: a run still unfinished after this was stopped.
    public static let staleAfter: TimeInterval = 120

    public var id: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var step: Step
    public var merchant: String?
    public var amountText: String?
    public var card: String?
    /// The movement it saved.
    public var movementId: String?
    /// The amount could not be read: the movement waits in «Por revisar».
    public var needsReview: Bool
    /// Who set the category on its own (`DecisionSource` raw value), or nil.
    public var categorySource: String?
    public var error: String?

    public init(id: String = UUID().uuidString, startedAt: Date = Date(), merchant: String?, amountText: String?, card: String?) {
        self.id = id
        self.startedAt = startedAt
        self.step = .started
        self.merchant = merchant.map { String($0.prefix(200)) }
        self.amountText = amountText.map { String($0.prefix(100)) }
        self.card = card.map { String($0.prefix(100)) }
        self.needsReview = false
    }

    private func stale(_ now: Date) -> Bool { now.timeIntervalSince(startedAt) > Self.staleAfter }

    public func status(now: Date) -> Status {
        switch step {
        case .failed: return .failed
        case .done, .saved:
            if step == .saved && !stale(now) { return .running }
            return needsReview ? .review : .saved
        case .started: return stale(now) ? .interrupted : .running
        }
    }

    /// Saved, but iOS stopped the run before it finished syncing and notifying.
    public func cutShort(now: Date) -> Bool { step == .saved && stale(now) }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

public enum CaptureLogRules {
    /// About two or three months of payments for one person.
    public static let maxRuns = 300

    /// Newest first, at most `maxRuns`.
    public static func adding(_ run: CaptureRun, to runs: [CaptureRun]) -> [CaptureRun] {
        Array(([run] + runs.filter { $0.id != run.id }).prefix(maxRuns))
    }

    public static func updating(_ id: String, in runs: [CaptureRun], _ change: (inout CaptureRun) -> Void) -> [CaptureRun] {
        runs.map { run in
            var r = run
            if r.id == id { change(&r) }
            return r
        }
    }

    public struct Summary: Equatable, Sendable {
        public var saved = 0
        public var failed = 0
        public var interrupted = 0
        public init(saved: Int = 0, failed: Int = 0, interrupted: Int = 0) {
            self.saved = saved; self.failed = failed; self.interrupted = interrupted
        }
    }

    /// Runs since a date: saved (including those waiting in «Por revisar»), failed and interrupted.
    public static func summary(_ runs: [CaptureRun], since: Date, now: Date) -> Summary {
        var s = Summary()
        for r in runs where r.startedAt >= since {
            switch r.status(now: now) {
            case .saved, .review: s.saved += 1
            case .failed: s.failed += 1
            case .interrupted: s.interrupted += 1
            case .running: break
            }
        }
        return s
    }
}
