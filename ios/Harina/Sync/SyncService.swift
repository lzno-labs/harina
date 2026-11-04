// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import SwiftData

enum SyncError: Error {
    case notLinked, unauthorized, server(Int), invalidLinkCode
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
        Keychain.save(link.token)
        AppSettings.serverURL = server
        AppSettings.lastSeq = 0
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

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let server = AppSettings.serverURL, let token = Keychain.load() else { throw SyncError.notLinked }
        var req = URLRequest(url: URL(string: path, relativeTo: server)!)
        req.httpMethod = method
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
