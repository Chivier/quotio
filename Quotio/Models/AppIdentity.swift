//
//  AppIdentity.swift
//  Quotio
//

import Foundation

nonisolated enum AppIdentity {
    static let productionBundleIdentifier = "app.bytrong.quotio"
    static let legacyBundleIdentifiers = [
        "dev.quotio.desktop",
        "proseek.io.vn.Quotio",
    ]

    private static let userDefaultsMigrationKey = "migratedToByTrongAppIdentity"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? productionBundleIdentifier
    }

    static var isProduction: Bool {
        bundleIdentifier == productionBundleIdentifier
    }

    static var isDevelopmentBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func keychainService(suffix: String) -> String {
        keychainService(
            suffix: suffix,
            bundleIdentifier: bundleIdentifier,
            isDevelopmentBuild: isDevelopmentBuild
        )
    }

    static func keychainService(
        suffix: String,
        bundleIdentifier: String,
        isDevelopmentBuild: Bool
    ) -> String {
        let namespace = isDevelopmentBuild && bundleIdentifier == productionBundleIdentifier
            ? "\(bundleIdentifier).debug"
            : bundleIdentifier
        return "\(namespace).\(suffix)"
    }

    static func legacyKeychainServices(suffix: String) -> [String] {
        legacyBundleIdentifiers.map { "\($0).\(suffix)" } + ["com.quotio.\(suffix)"]
    }

    @discardableResult
    static func migrateLegacyUserDefaults(
        defaults: UserDefaults = .standard,
        currentBundleIdentifier: String = bundleIdentifier
    ) -> Bool {
        guard currentBundleIdentifier == productionBundleIdentifier else { return false }

        var currentDomain = defaults.persistentDomain(forName: currentBundleIdentifier) ?? [:]
        guard currentDomain[userDefaultsMigrationKey] as? Bool != true else { return false }

        let legacyDomains = legacyBundleIdentifiers.compactMap {
            defaults.persistentDomain(forName: $0)
        }
        currentDomain = mergingUserDefaults(current: currentDomain, legacyDomains: legacyDomains)
        currentDomain[userDefaultsMigrationKey] = true
        defaults.setPersistentDomain(currentDomain, forName: currentBundleIdentifier)
        return true
    }

    static func mergingUserDefaults(
        current: [String: Any],
        legacyDomains: [[String: Any]]
    ) -> [String: Any] {
        var merged = current
        for legacyDomain in legacyDomains {
            for (key, value) in legacyDomain where merged[key] == nil {
                merged[key] = value
            }
        }
        return merged
    }
}
