// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI

/// Every run of «Registrar pago en Harina» on this iPhone, to find out why a payment is missing
/// (docs/design/capture-log.md). Kept only here; the person can share a copy.
struct CaptureLogView: View {
    @Query(filter: #Predicate<Movement> { $0.source == "apple_pay" }) private var captured: [Movement]
    @State private var runs: [CaptureRun] = []
    @State private var confirmClear = false

    var body: some View {
        let now = Date()
        let byId = Dictionary(captured.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        List {
            Section {
                Text("capturelog.intro").font(.subheadline).foregroundStyle(.secondary)
                if !runs.isEmpty {
                    let s = CaptureLogRules.summary(runs, since: now.addingTimeInterval(-30 * 86400), now: now)
                    Text("capturelog.summary \(s.saved) \(s.failed) \(s.interrupted)").font(.subheadline.weight(.semibold))
                }
            }
            if runs.isEmpty {
                Section { Text("capturelog.empty").foregroundStyle(.secondary) }
            } else {
                Section("capturelog.runs") {
                    ForEach(runs) { run in
                        let movement = run.movementId.flatMap { byId[$0] }
                        if let movement, !movement.deleted {
                            NavigationLink { MovementForm(movement: movement) } label: { CaptureRunRow(run: run, movement: movement, now: now) }
                        } else {
                            CaptureRunRow(run: run, movement: movement, now: now)
                        }
                    }
                }
            }
            Section {
                Text("capturelog.missing.text").font(.subheadline)
                Label("capturelog.missing.notTap", systemImage: "creditcard")
                Label("capturelog.missing.late", systemImage: "clock.badge.exclamationmark")
                Label("capturelog.missing.ask", systemImage: "hand.raised")
                Label("capturelog.missing.off", systemImage: "switch.2")
                NavigationLink("settings.automationHelp") { AutomationHelpView() }
            } header: {
                Text("capturelog.missing.title")
            }
            .font(.subheadline)
        }
        .navigationTitle("capturelog.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: CaptureLog.report(runs, now: now)) { Label("capturelog.share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmClear = true } label: { Label("capturelog.clear", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(runs.isEmpty)
            }
        }
        .confirmationDialog("capturelog.clearConfirm", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("capturelog.clear", role: .destructive) {
                CaptureLog.clear()
                runs = []
            }
        }
        .onAppear { runs = CaptureLog.runs }
        .refreshable { runs = CaptureLog.runs }
    }
}

/// One run: what Wallet sent, when, and how it ended.
struct CaptureRunRow: View {
    let run: CaptureRun
    let movement: Movement?
    let now: Date

    var body: some View {
        let status = run.status(now: now)
        HStack(alignment: .top, spacing: 12) {
            icon(status)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: run.merchant ?? L("capturelog.noMerchant")).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: run.amountText ?? "").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(verbatim: [run.startedAt.formatted(date: .abbreviated, time: .shortened), run.card].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: CaptureLog.statusText(run, now: now)).font(.caption.weight(.semibold)).foregroundStyle(color(status))
                if let detail = detail(status) {
                    Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func icon(_ status: CaptureRun.Status) -> some View {
        switch status {
        case .running: ProgressView()
        case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.earn)
        case .review: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.spend)
        case .interrupted: Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warn)
        }
    }

    private func color(_ status: CaptureRun.Status) -> Color {
        switch status {
        case .saved: return Theme.earn
        case .failed: return Theme.spend
        case .review, .interrupted: return Theme.warn
        case .running: return .secondary
        }
    }

    /// The error, how long it took, and whether the movement reached the server.
    private func detail(_ status: CaptureRun.Status) -> String? {
        var parts: [String] = []
        if let e = run.error { parts.append(e) }
        if status == .saved || status == .review {
            if let movement {
                if movement.deleted {
                    parts.append(L("capturelog.deleted"))
                } else if SyncService.shared.isLinked {
                    parts.append(L(movement.dirty ? "capturelog.sync.pending" : "capturelog.sync.sent"))
                }
            } else if run.movementId != nil {
                parts.append(L("capturelog.deleted"))
            }
        }
        if let d = run.duration { parts.append(String(format: L("capturelog.duration"), d.formatted(.number.precision(.fractionLength(1))))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
