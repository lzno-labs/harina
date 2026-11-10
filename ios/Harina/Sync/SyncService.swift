// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import SwiftData

enum SyncError: Error {
    case notLinked, unauthorized, server(Int), invalidLinkCode, signupClosed
}

/// Offline-first sync (docs/adr/0002-sync.md): push local changes, then pull since the last seq.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: SyncError?

    var isLinked: Bool { AppSettings.serverURL != nil && Keychain.load() != nil }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: linking

    func link(server: URL, code: String, deviceName: String) async throws {
        var req = URLRequest(url: server.appending(path: "api/devices/link"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "name": deviceName])
        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw SyncError.server(0) }
        if http.statusCode == 400 { throw SyncError.invalidLinkCode }
        guard http.statusCode == 200 else { throw SyncError.server(http.statusCode) }
        let link = try JSONDecoder().decode(LinkResponse.self, from: data)
        adopt(server: server, token: link.token)
    }

    /// Creates a new account on the server with this iPhone as its first device
    /// (docs/design/people-and-spaces.md). Everything already on the phone goes to it.
    func signUp(server: URL, deviceName: String) async throws {
        var req = URLRequest(url: server.appending(path: "api/auth/signup/device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["deviceName": deviceName])
        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw SyncError.server(0) }
        if http.statusCode == 403 || http.statusCode == 429 { throw SyncError.signupClosed }
        guard http.statusCode == 200 else { throw SyncError.server(http.statusCode) }
        let link = try JSONDecoder().decode(LinkResponse.self, from: data)
        adopt(server: server, token: link.token)
    }

    /// A one-time code to open this account on the web (valid 10 minutes).
    func webCode() async throws -> String {
        struct Code: Decodable { let code: String }
        return try JSONDecoder().decode(Code.self, from: try await request("/api/auth/web-code", method: "POST", body: Data("{}".utf8), timeout: 10)).code
    }

    /// Starts syncing with an account: the whole local history goes up, then everything comes down.
    private func adopt(server: URL, token: String) {
        Keychain.save(token)
        AppSettings.serverURL = server
        AppSettings.lastSeq = 0
        for m in (try? context.fetch(FetchDescriptor<Movement>())) ?? [] { m.dirty = true }
        for c in (try? context.fetch(FetchDescriptor<CategoryItem>())) ?? [] { c.dirty = true }
        for a in (try? context.fetch(FetchDescriptor<AccountItem>())) ?? [] { a.dirty = true }
        try? context.save()
    }

    func unlink() {
        Keychain.delete()
        AppSettings.serverURL = nil
        AppSettings.lastSeq = 0
    }

    // MARK: sync

    /// Safe to call any time; does nothing when not linked or already running.
    func sync() async {
        guard isLinked, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await pushDirty()
            try await pullAll()
            lastSync = Date()
            lastError = nil
        } catch let e as SyncError {
            lastError = e
        } catch {
            lastError = .server(0) // offline or timeout: everything stays queued locally
        }
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        guard let server = AppSettings.serverURL, let token = Keychain.load() else { throw SyncError.notLinked }
        var req = URLRequest(url: URL(string: path, relativeTo: server)!)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, res) = try await session.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw SyncError.unauthorized }
        guard status == 200 else { throw SyncError.server(status) }
        return data
    }

    private var context: ModelContext { Store.container.mainContext }

    private func pushDirty() async throws {
        let movements = try context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.dirty == true }))
        let categories = try context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.dirty == true }))
        let accounts = try context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.dirty == true }))
        let all = SyncRecords(accounts: accounts.map(\.dto), categories: categories.map(\.dto), transactions: movements.map(\.dto))
        guard !all.isEmpty else { return }
        // The server takes up to 500 records per push.
        for chunk in Self.chunks(all, size: 400) {
            let data = try await request("/api/sync", method: "POST", body: JSONEncoder().encode(PushRequest(changes: chunk)))
            let res = try JSONDecoder().decode(PushResponse.self, from: data)
            apply(res.records, pushed: chunk)
        }
        try context.save()
    }

    private func pullAll() async throws {
        while true {
            let data = try await request("/api/sync?since=\(AppSettings.lastSeq)")
            let res = try JSONDecoder().decode(PullResponse.self, from: data)
            apply(res.records, pushed: nil)
            try context.save()
            AppSettings.lastSeq = res.seq
            if !res.more { break }
        }
    }

    /// Applies server records. After a push, a pushed record edited again meanwhile stays dirty.
    private func apply(_ r: SyncRecords, pushed: SyncRecords?) {
        for dto in r.transactions {
            let id = dto.id
            if let local = try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.id == id })).first {
                let sentAt = pushed?.transactions.first { $0.id == id }?.updated_at
                if let sentAt, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(Movement(dto, dirty: false))
            }
        }
        for dto in r.categories {
            let id = dto.id
            if let local = try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.id == id })).first {
                let sentAt = pushed?.categories.first { $0.id == id }?.updated_at
                if let sentAt, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(CategoryItem(dto, dirty: false))
            }
        }
        for dto in r.accounts {
            let id = dto.id
            if let local = try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.id == id })).first {
                let sentAt = pushed?.accounts.first { $0.id == id }?.updated_at
                if let sentAt, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(AccountItem(dto, dirty: false))
            }
        }
    }

    private static func chunks(_ r: SyncRecords, size: Int) -> [SyncRecords] {
        // Accounts and categories first, so movements never point at a record the server lacks.
        var out: [SyncRecords] = []
        if !r.accounts.isEmpty || !r.categories.isEmpty {
            out.append(SyncRecords(accounts: r.accounts, categories: r.categories))
        }
        var i = 0
        while i < r.transactions.count {
            out.append(SyncRecords(transactions: Array(r.transactions[i..<min(i + size, r.transactions.count)])))
            i += size
        }
        return out
    }
}

// MARK: - Hosted category decider (docs/design/hosted-decision-model.md)

struct DeciderStatus: Decodable, Sendable {
    let available: Bool
    let consent: Bool
}

extension SyncService {
    /// Whether the linked server offers the hosted decider and the person agreed to use it.
    func deciderStatus() async -> DeciderStatus? {
        guard isLinked, let data = try? await request("/api/decider", timeout: 10) else { return nil }
        let status = try? JSONDecoder().decode(DeciderStatus.self, from: data)
        if let status { AppSettings.hostedDecider = status.available && status.consent }
        return status
    }

    func setDeciderConsent(_ on: Bool) async throws -> DeciderStatus {
        let body = try JSONSerialization.data(withJSONObject: ["on": on])
        let status = try JSONDecoder().decode(DeciderStatus.self, from: try await request("/api/decider/consent", method: "POST", body: body, timeout: 10))
        AppSettings.hostedDecider = status.available && status.consent
        return status
    }

    /// The hosted decider's pick for a payment, or nil (offline, slow, no consent, nothing sure).
    func hostedCategory(merchant: String?, amountMinor: Int64, currency: String) async -> (id: String, confidence: Double)? {
        guard isLinked, let merchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty else { return nil }
        struct Body: Encodable { let merchant: String; let amount_minor: Int64; let currency: String }
        struct Answer: Decodable { let category_id: String?; let confidence: Double }
        do {
            let data = try await request("/api/categorize", method: "POST",
                                         body: JSONEncoder().encode(Body(merchant: merchant, amount_minor: amountMinor, currency: currency)),
                                         timeout: 5)
            let a = try JSONDecoder().decode(Answer.self, from: data)
            return a.category_id.map { ($0, a.confidence) }
        } catch SyncError.server(let code) where code == 403 || code == 404 {
            AppSettings.hostedDecider = false // consent withdrawn elsewhere, or the server stopped offering it
            return nil
        } catch {
            return nil
        }
    }
}

