// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import SwiftData

enum SyncError: Error {
    case notLinked, unauthorized, server(Int), invalidLinkCode, signupClosed, needsConnection
}

/// Offline-first sync (docs/adr/0002-sync.md): push local changes, then pull since the last seq.
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: SyncError?
    /// The person's spaces (personal first), refreshed on every sync.
    @Published private(set) var spaces: [SpaceInfo] = Spaces.list

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
        for x in (try? context.fetch(FetchDescriptor<ReminderItem>())) ?? [] { x.dirty = true }
        for x in (try? context.fetch(FetchDescriptor<BudgetItem>())) ?? [] { x.dirty = true }
        for x in (try? context.fetch(FetchDescriptor<PotItem>())) ?? [] { x.dirty = true }
        try? context.save()
    }

    func unlink() {
        Keychain.delete()
        AppSettings.serverURL = nil
        AppSettings.lastSeq = 0
        adoptSpaces([])
    }

    // MARK: sync

    /// Safe to call any time; does nothing when not linked or already running.
    func sync() async {
        guard isLinked, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await refreshSpaces()
            try await pushDirty()
            try await pullAll()
            await Reminders.reschedule()
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
        let reminders = try context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.dirty == true }))
        let budgets = try context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.dirty == true }))
        let pots = try context.fetch(FetchDescriptor<PotItem>(predicate: #Predicate { $0.dirty == true }))
        let all = SyncRecords(accounts: accounts.map(\.dto), categories: categories.map(\.dto), transactions: movements.map(\.dto),
                              reminders: reminders.map(\.dto), budgets: budgets.map(\.dto), pots: pots.map(\.dto))
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
            if let spaces = res.spaces { adoptSpaces(spaces) }
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
                // A moved movement leaves a tombstone in its old space: the live copy is the one that counts.
                if (dto.deleted ?? 0) != 0 && Spaces.local(dto.space_id) != local.space { continue }
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
            let uid = Spaces.uid(Spaces.local(dto.space_id), id)
            if let local = try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.uid == uid })).first {
                let sentAt = pushed?.categories.first { $0.id == id && Spaces.local($0.space_id) == local.space }?.updated_at
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
                if (dto.deleted ?? 0) != 0 && Spaces.local(dto.space_id) != local.space { continue }
                let sentAt = pushed?.accounts.first { $0.id == id }?.updated_at
                if let sentAt, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(AccountItem(dto, dirty: false))
            }
        }
        for dto in r.reminders {
            let uid = Spaces.uid(Spaces.local(dto.space_id), dto.id)
            if let local = try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.uid == uid })).first {
                if let sentAt = pushed?.reminders.first(where: { $0.id == dto.id })?.updated_at, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(ReminderItem(dto, dirty: false))
            }
        }
        for dto in r.budgets {
            let uid = Spaces.uid(Spaces.local(dto.space_id), dto.id)
            if let local = try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.uid == uid })).first {
                if let sentAt = pushed?.budgets.first(where: { $0.id == dto.id })?.updated_at, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(BudgetItem(dto, dirty: false))
            }
        }
        for dto in r.pots {
            let uid = Spaces.uid(Spaces.local(dto.space_id), dto.id)
            if let local = try? context.fetch(FetchDescriptor<PotItem>(predicate: #Predicate { $0.uid == uid })).first {
                if let sentAt = pushed?.pots.first(where: { $0.id == dto.id })?.updated_at, local.updatedAt > sentAt { continue }
                if pushed != nil || SyncRules.serverWins(localUpdatedAt: local.updatedAt, localDirty: local.dirty, serverUpdatedAt: dto.updated_at) {
                    local.update(from: dto)
                }
            } else {
                context.insert(PotItem(dto, dirty: false))
            }
        }
    }

    private static func chunks(_ r: SyncRecords, size: Int) -> [SyncRecords] {
        // Accounts and categories first, so movements never point at a record the server lacks.
        var out: [SyncRecords] = []
        if !r.accounts.isEmpty || !r.categories.isEmpty || !r.reminders.isEmpty || !r.budgets.isEmpty || !r.pots.isEmpty {
            out.append(SyncRecords(accounts: r.accounts, categories: r.categories, reminders: r.reminders, budgets: r.budgets, pots: r.pots))
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

// MARK: - Spaces (docs/design/people-and-spaces.md)

extension SyncService {
    struct SpacesResponse: Decodable { let spaces: [SpaceInfo] }

    func refreshSpaces() async throws {
        let r = try JSONDecoder().decode(SpacesResponse.self, from: try await request("/api/spaces", timeout: 15))
        adoptSpaces(r.spaces)
    }

    /// New list from the server: a joined space pulls its history; a space that is gone leaves the phone.
    func adoptSpaces(_ new: [SpaceInfo]) {
        let before = Set(Spaces.list.map(\.id))
        let rowsUsedPersonalId = Spaces.personalId == nil && !new.isEmpty
        Spaces.list = new
        spaces = new
        let ids = Set(new.filter { !$0.isPersonal }.map(\.id))
        if !before.isEmpty, !Set(new.map(\.id)).subtracting(before).isEmpty { AppSettings.lastSeq = 0 }
        if rowsUsedPersonalId { AppSettings.lastSeq = 0 }
        for m in (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(m.space) {
            context.delete(m)
        }
        for c in (try? context.fetch(FetchDescriptor<CategoryItem>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(c.space) {
            context.delete(c)
        }
        for a in (try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(a.space) {
            context.delete(a)
        }
        for x in (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(x.space) {
            context.delete(x)
        }
        for x in (try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(x.space) {
            context.delete(x)
        }
        for x in (try? context.fetch(FetchDescriptor<PotItem>(predicate: #Predicate { $0.space != "" }))) ?? [] where !ids.contains(x.space) {
            context.delete(x)
        }
        try? context.save()
    }

    private func spacesCall(_ path: String, method: String = "POST", body: [String: String] = [:]) async throws -> Data {
        let data = try await request(path, method: method, body: try JSONSerialization.data(withJSONObject: body), timeout: 15)
        if let r = try? JSONDecoder().decode(SpacesResponse.self, from: data) { adoptSpaces(r.spaces) }
        return data
    }

    func createSpace(name: String) async throws -> String {
        struct Created: Decodable { let id: String }
        let id = try JSONDecoder().decode(Created.self, from: try await spacesCall("/api/spaces", body: ["name": name])).id
        await sync()
        return id
    }

    func invite(to space: String) async throws -> String {
        struct Code: Decodable { let code: String }
        return try JSONDecoder().decode(Code.self, from: try await request("/api/spaces/\(space)/invites", method: "POST", body: Data("{}".utf8), timeout: 15)).code
    }

    /// Joins with a one-time invite code; returns the space's id.
    func join(code: String) async throws -> String {
        struct Joined: Decodable { struct S: Decodable { let id: String }; let space: S }
        let id = try JSONDecoder().decode(Joined.self, from: try await spacesCall("/api/invites/accept", body: ["code": code])).space.id
        await sync()
        return id
    }

    func leave(_ space: String) async throws { _ = try await spacesCall("/api/spaces/\(space)/leave") }
    func deleteSpace(_ space: String) async throws { _ = try await spacesCall("/api/spaces/\(space)", method: "DELETE") }
    func renameSpace(_ space: String, name: String) async throws { _ = try await spacesCall("/api/spaces/\(space)", method: "PATCH", body: ["name": name]) }
    func setMyName(_ name: String) async throws {
        _ = try await request("/api/me", method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["name": name]), timeout: 15)
        try await refreshSpaces()
    }

    /// Moves a movement to another space now (online): a tombstone where it was, the same row there.
    func move(_ m: Movement, to space: String) async throws {
        guard isLinked else { throw SyncError.needsConnection }
        let now = max(SyncRules.now(), m.updatedAt + 1)
        var old = m.dto
        old.deleted = 1; old.updated_at = now
        var moved = m.dto
        moved.space_id = Spaces.wire(space); moved.updated_at = now; moved.deleted = 0
        if let c = m.categoryId, CategoryStore.item(c, space: space, context).map({ !$0.deleted }) != true { moved.category_id = nil }
        if let a = m.accountId, (try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.id == a })).first)?.space != space {
            moved.account_id = nil
        }
        _ = try await request("/api/sync", method: "POST", body: JSONEncoder().encode(PushRequest(changes: SyncRecords(transactions: [old, moved]))), timeout: 15)
        m.update(from: moved)
        try? context.save()
    }

    /// Moves a card to another space: its next Apple Pay payments land there.
    func move(_ a: AccountItem, to space: String) async throws {
        guard isLinked else { throw SyncError.needsConnection }
        let now = max(SyncRules.now(), a.updatedAt + 1)
        var old = a.dto
        old.deleted = 1; old.updated_at = now
        var moved = a.dto
        moved.space_id = Spaces.wire(space); moved.updated_at = now; moved.deleted = 0
        _ = try await request("/api/sync", method: "POST", body: JSONEncoder().encode(PushRequest(changes: SyncRecords(accounts: [old, moved]))), timeout: 15)
        a.update(from: moved)
        try? context.save()
    }
}

