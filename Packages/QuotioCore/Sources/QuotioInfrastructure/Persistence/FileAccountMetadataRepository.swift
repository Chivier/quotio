import Foundation
import QuotioApplication
import QuotioDomain

public actor FileAccountMetadataRepository: AccountMetadataRepository {
    private struct Payload: Codable {
        var accounts: [Account] = []
        var disabledAccountIDs: Set<String> = []
        // Optional so files written before these markers existed decode unchanged.
        var removedAccountIDs: Set<String>?
        // Only identities proven equivalent from the same source are linked.
        var accountAliases: [String: String]?
    }

    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Quotio/Monitor/accounts-v1.json")
    }

    /// Stored accounts minus the ones the user removed. Disabled markers stay separate,
    /// exactly as persisted; discovery applies them.
    public func accounts() -> [Account] {
        let payload = load()
        let removed = Set((payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
        return payload.accounts.filter { !removed.contains(canonicalID($0.id, in: payload)) }
    }

    public func disabledAccountIDs() -> Set<String> {
        let payload = load()
        return Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
    }

    public func removedAccountIDs() async -> Set<String> {
        let payload = load()
        return Set((payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
    }

    public func saveAccount(_ account: Account) throws {
        var payload = load()
        let identity = canonicalID(account.id, in: payload)
        // A background write must not resurrect an account the user removed; a
        // user-initiated save clears the marker through `setRemoved(false, ...)` first.
        if payload.removedAccountIDs?.contains(where: { canonicalID($0, in: payload) == identity }) == true {
            throw CredentialVaultError.accountRemoved
        }
        payload.accounts.removeAll { $0.id == account.id }
        payload.accounts.append(account)
        try save(payload)
    }

    public func deleteAccount(_ accountID: String) throws {
        var payload = load()
        let identity = canonicalID(accountID, in: payload)
        payload.accounts.removeAll { $0.id == accountID }
        payload.disabledAccountIDs = payload.disabledAccountIDs.filter {
            canonicalID($0, in: payload) != identity
        }
        // Discovery may still find this identity in another source; keep it hidden.
        payload.removedAccountIDs = (payload.removedAccountIDs ?? []).union([identity])
        try save(payload)
    }

    public func setDisabled(_ disabled: Bool, accountID: String) throws {
        var payload = load()
        let identity = canonicalID(accountID, in: payload)
        if disabled {
            payload.disabledAccountIDs.insert(identity)
        } else {
            payload.disabledAccountIDs = payload.disabledAccountIDs.filter {
                canonicalID($0, in: payload) != identity
            }
        }
        try save(payload)
    }

    public func isRemoved(_ accountID: String) async -> Bool {
        let payload = load()
        let identity = canonicalID(accountID, in: payload)
        return payload.removedAccountIDs?.contains { canonicalID($0, in: payload) == identity } == true
    }

    public func setRemoved(_ removed: Bool, accountID: String) async throws {
        var payload = load()
        let identity = canonicalID(accountID, in: payload)
        var removedIDs = payload.removedAccountIDs ?? []
        if removed {
            removedIDs.insert(identity)
            payload.disabledAccountIDs = payload.disabledAccountIDs.filter {
                canonicalID($0, in: payload) != identity
            }
        } else {
            let before = removedIDs.count
            removedIDs = removedIDs.filter { canonicalID($0, in: payload) != identity }
            guard removedIDs.count != before else { return }
        }
        payload.removedAccountIDs = removedIDs.isEmpty ? nil : removedIDs
        try save(payload)
    }

    @discardableResult
    public func restoreRemovedAccounts() async throws -> Int {
        var payload = load()
        let count = payload.removedAccountIDs?.count ?? 0
        guard count > 0 else { return 0 }
        payload.removedAccountIDs = nil
        try save(payload)
        return count
    }

    public func reconcileAliases(_ aliasesByIdentity: [String: Set<String>]) async throws {
        var payload = load()
        // Freeze existing markers onto the previously proven identity before a reused
        // filename can be associated with a different login.
        payload.removedAccountIDs = payload.removedAccountIDs.map {
            Set($0.map { canonicalID($0, in: payload) })
        }
        payload.disabledAccountIDs = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        var targets: [String: Set<String>] = [:]
        for (identity, aliases) in aliasesByIdentity {
            for alias in aliases { targets[alias, default: []].insert(identity) }
        }
        var aliases = payload.accountAliases ?? [:]
        for (alias, identities) in targets {
            // An email or generic label shared by several profiles proves nothing; it
            // must never let one marker hide all of those accounts.
            if identities.count == 1, let identity = identities.first, alias != identity {
                aliases[alias] = identity
            } else {
                aliases.removeValue(forKey: alias)
            }
        }
        guard aliases != (payload.accountAliases ?? [:]) else { return }
        payload.accountAliases = aliases.isEmpty ? nil : aliases
        payload.removedAccountIDs = payload.removedAccountIDs.map {
            Set($0.map { canonicalID($0, in: payload) })
        }
        payload.disabledAccountIDs = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        try save(payload)
    }

    public func filteringAccounts(_ accounts: [Account]) async -> [Account] {
        let payload = load()
        let removed = Set((payload.removedAccountIDs ?? []).map { canonicalID($0, in: payload) })
        let disabled = Set(payload.disabledAccountIDs.map { canonicalID($0, in: payload) })
        var selected: [String: Account] = [:]
        var order: [String] = []
        for var account in accounts {
            let identity = canonicalID(account.id, in: payload)
            guard !removed.contains(identity) else { continue }
            account.isDisabled = disabled.contains(identity)
                || payload.disabledAccountIDs.contains(account.id)
            if let existing = selected[identity] {
                if existing.source.priority > account.source.priority
                    || (existing.source.priority == account.source.priority && existing.id == identity) {
                    continue
                }
            } else {
                order.append(identity)
            }
            selected[identity] = account
        }
        return order.compactMap { selected[$0] }
    }

    public func excludedQuotaAccountIDs() async -> Set<String> {
        let payload = load()
        let excluded = Set(
            payload.disabledAccountIDs.union(payload.removedAccountIDs ?? [])
                .map { canonicalID($0, in: payload) }
        )
        return excluded.union(
            (payload.accountAliases ?? [:]).compactMap { excluded.contains($0.value) ? $0.key : nil }
        )
    }

    private func canonicalID(_ id: String, in payload: Payload) -> String {
        payload.accountAliases?[id] ?? id
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url) else { return Payload() }
        if var payload = try? JSONDecoder().decode(Payload.self, from: data) {
            let removedIDs = Set(
                payload.accounts
                    .filter { $0.providerID.rawValue == "gemini-cli" }
                    .map(\.id)
            )
            guard !removedIDs.isEmpty else { return payload }
            payload.accounts.removeAll { removedIDs.contains($0.id) }
            payload.disabledAccountIDs.subtract(removedIDs)
            try? save(payload)
            return payload
        }

        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return Payload() }
        let removedIDs = Set(accounts.compactMap { account in
            account["provider"] as? String == "gemini-cli" ? account["id"] as? String : nil
        })
        guard !removedIDs.isEmpty else { return Payload() }

        object["accounts"] = accounts.filter { $0["provider"] as? String != "gemini-cli" }
        if let disabledIDs = object["disabledAccountIDs"] as? [String] {
            object["disabledAccountIDs"] = disabledIDs.filter { !removedIDs.contains($0) }
        }
        guard let migratedData = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(Payload.self, from: migratedData) else {
            return Payload()
        }
        try? save(payload)
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}
