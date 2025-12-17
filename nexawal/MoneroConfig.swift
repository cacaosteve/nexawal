//
//  MoneroConfig.swift
//  nexawal
//
//  Configuration for Monero node connection
//  Matches supermegamart's MoneroConfig setup
//

import Foundation
import Darwin

struct MoneroConfig {
    // These are simple constants. Mark them as nonisolated (not unsafe) so they can be used from
    // nonisolated computed properties without triggering global-actor isolation warnings, while
    // still avoiding unnecessary `unsafe` annotations.
    nonisolated static let defaultAddress = "192.168.4.137:18081"
    nonisolated static let userDefaultsKey = "monero_daemon_address"

    // I2P defaults and keys
    nonisolated static let defaultI2PRPCAddress = "cvxtgqjorfif6i5x5fenys6fj7hzddbgavpyutps6gphywnlklqa.b32.i2p:18089"
    nonisolated static let userDefaultsI2PModeKey = "monero_i2p_mode"
    nonisolated static let userDefaultsI2PRPCKey = "monero_i2p_rpc_address"
    nonisolated static let userDefaultsI2PProxyKey = "monero_i2p_http_proxy"
    // Gap limit key and default
        nonisolated static let userDefaultsGapLimitKey = "monero_gap_limit"
        nonisolated static let defaultGapLimit: UInt32 = 50
        // Scan tuning keys and defaults
        nonisolated static let userDefaultsScanParKey = "walletcore_scan_par"
        nonisolated static let userDefaultsScanBatchKey = "walletcore_scan_batch"
        nonisolated static let defaultScanPar: Int = 0
        nonisolated static let defaultScanBatch: Int = 200
        // Account lookahead (major) key and default
        nonisolated static let userDefaultsAccountGapKey = "walletcore_account_gap"
        nonisolated static let defaultAccountGap: Int = 1
        // Network policy keys and defaults (clearnet only, i2p only, hybrid: scan clearnet, broadcast i2p)
        nonisolated static let userDefaultsNetworkPolicyKey = "monero_network_policy"
        nonisolated static let defaultNetworkPolicyRaw = "clearnet"

        enum NetworkPolicy: String {
            case clearnet     // scan + broadcast over clearnet
            case i2p          // scan + broadcast over I2P
            case hybrid       // scan over clearnet, broadcast over I2P
        }

        // Current network policy (defaults to clearnet)
        nonisolated static var networkPolicy: NetworkPolicy {
            let raw = UserDefaults.standard.string(forKey: userDefaultsNetworkPolicyKey) ?? defaultNetworkPolicyRaw
            return NetworkPolicy(rawValue: raw) ?? .clearnet
        }

        // Update network policy (persisted)
        @MainActor
        static func setNetworkPolicy(_ policy: NetworkPolicy) {
            UserDefaults.standard.set(policy.rawValue, forKey: userDefaultsNetworkPolicyKey)
        }

        // Resolve plain host:port used for scanning based on policy
        nonisolated static func scanNodeAddress() -> String {
            switch networkPolicy {
            case .clearnet, .hybrid:
                return daemonAddress
            case .i2p:
                return i2pRPCAddress
            }
        }

        // Resolve plain host:port used for broadcasting based on policy
        nonisolated static func broadcastNodeAddress() -> String {
            switch networkPolicy {
            case .clearnet:
                return daemonAddress
            case .i2p, .hybrid:
                return i2pRPCAddress
            }
        }

        // Helper to normalize into full URL with protocol
        private nonisolated static func urlFromAddress(_ address: String) -> String {
            if address.hasPrefix("http://") || address.hasPrefix("https://") {
                return address
            }
            return "http://\(address)"
        }

        // Effective scan/broadcast URLs
        nonisolated static func scanNodeURL() -> String {
            // Apply account lookahead to core via environment for the scanning path
            setenv("WALLETCORE_ACCOUNT_GAP", "\(accountGap)", 1)
            return urlFromAddress(scanNodeAddress())
        }

        nonisolated static func broadcastNodeURL() -> String {
            urlFromAddress(broadcastNodeAddress())
        }
        // Scan mode and per-node profiles (Auto/Manual + last known good tuning)
        nonisolated static let userDefaultsScanModeKey = "monero_scan_mode"
        nonisolated static let userDefaultsScanProfilesKey = "monero_scan_profiles"
        nonisolated static let defaultScanModeRaw = "auto"

        enum ScanMode: String {
            case auto
            case manual
        }

        struct ScanProfile: Codable {
            var lastGoodPar: Int
            var lastGoodBatch: Int
            var lockedUntil: TimeInterval? // epoch seconds until which parallel is locked out
        }

        // Baseline reliable tuning used by Auto mode for restores and fallback
        nonisolated static let baselinePar: Int = 0
        nonisolated static let baselineBatch: Int = 150

    /// Monero daemon address (hostname:port format)
    /// Defaults to local dev server, can be overridden via environment or settings
    /// This is nonisolated and safe to call from any context
    nonisolated static var daemonAddress: String {
        // Access UserDefaults safely from nonisolated context
        // UserDefaults.standard is thread-safe for reading
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            return saved
        }
        return defaultAddress
    }

    /// Whether to route RPC calls over I2P
    /// Stored in UserDefaults under userDefaultsI2PModeKey
    nonisolated static var useI2P: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsI2PModeKey)
    }

    /// Enable or disable I2P mode (persisted)
    @MainActor
    static func setUseI2P(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsI2PModeKey)
    }

    /// I2P RPC address (hostname:port, typically .b32.i2p:port)
    nonisolated static var i2pRPCAddress: String {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsI2PRPCKey), !saved.isEmpty {
            return saved
        }
        return defaultI2PRPCAddress
    }

    /// Set I2P RPC address (persisted)
    @MainActor
    static func setI2PRPCAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: userDefaultsI2PRPCKey)
    }

    /// I2P HTTP proxy address (host:port). Optional.
    nonisolated static var i2pHTTPProxyAddress: String? {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsI2PProxyKey), !saved.isEmpty {
            return saved
        }
        return nil
    }

    /// Set or clear I2P HTTP proxy address
    @MainActor
    static func setI2PHTTPProxyAddress(_ address: String?) {
        if let addr = address, !addr.isEmpty {
            UserDefaults.standard.set(addr, forKey: userDefaultsI2PProxyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsI2PProxyKey)
        }
    }

    /// Gap limit for scanning subaddresses (1...100000). Default is 50.
    /// Stored in UserDefaults under userDefaultsGapLimitKey
    nonisolated static var gapLimit: UInt32 {
        let v = UserDefaults.standard.integer(forKey: userDefaultsGapLimitKey)
        let value = (v > 0 ? v : Int(defaultGapLimit))
        let clamped = max(1, min(value, 100_000))
        return UInt32(clamped)
    }

    /// Set the gap limit (persisted). Values are clamped to [1, 100000].
    @MainActor
    static func setGapLimit(_ limit: UInt32) {
        let clamped = min(max(limit, 1), 100_000)
        UserDefaults.standard.set(Int(clamped), forKey: userDefaultsGapLimitKey)
    }

    /// Major account lookahead (number of accounts to scan starting from 0). Default is 1 (account 0 only).
    /// Stored in UserDefaults under userDefaultsAccountGapKey
    nonisolated static var accountGap: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsAccountGapKey)
        let value = (v > 0 ? v : defaultAccountGap)
        return max(1, min(value, 1_000))
    }

    /// Set the account lookahead (persisted). Values are clamped to [1, 1000].
    @MainActor
    static func setAccountGap(_ gap: Int) {
        let clamped = max(1, min(gap, 1_000))
        UserDefaults.standard.set(clamped, forKey: userDefaultsAccountGapKey)
    }

    // MARK: - Scan mode (Auto/Manual)

    nonisolated static var scanMode: ScanMode {
        let raw = UserDefaults.standard.string(forKey: userDefaultsScanModeKey) ?? defaultScanModeRaw
        return ScanMode(rawValue: raw) ?? .auto
    }

    @MainActor
    static func setScanMode(_ mode: ScanMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsScanModeKey)
    }

    // MARK: - Per-node scan profiles (Auto mode)

    // Effective node address (host:port) for keying profiles
    nonisolated static func effectiveNodeAddress() -> String {
        // Use the scanning address for tuning/profile keys
        return scanNodeAddress()
    }

    // Load/save entire profiles dictionary from UserDefaults
    nonisolated static func loadScanProfiles() -> [String: ScanProfile] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsScanProfilesKey) else {
            return [:]
        }
        if let dict = try? JSONDecoder().decode([String: ScanProfile].self, from: data) {
            return dict
        }
        return [:]
    }

    @MainActor
    static func saveScanProfiles(_ profiles: [String: ScanProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: userDefaultsScanProfilesKey)
        }
    }

    // Get current node profile, if any
    nonisolated static func profileForCurrentNode() -> ScanProfile? {
        let key = effectiveNodeAddress()
        return loadScanProfiles()[key]
    }

    // Choose tuning for current node based on ScanMode and profile (Auto mode)
    nonisolated static func chooseTuningForCurrentNode() -> (par: Int, batch: Int) {
        switch scanMode {
        case .manual:
            return (scanParallelism, scanBatchSize)
        case .auto:
            let now = Date().timeIntervalSince1970
            if let profile = profileForCurrentNode() {
                // If locked, use baseline reliable tuning
                if let lock = profile.lockedUntil, lock > now {
                    return (baselinePar, baselineBatch)
                }
                // Use last known good tuning
                return (max(0, profile.lastGoodPar), max(50, profile.lastGoodBatch))
            } else {
                // No profile yet: start reliable
                return (baselinePar, baselineBatch)
            }
        }
    }

    // Record a stall and lock parallel for a cooldown window; persist baseline tuning
    @MainActor
    static func recordParallelStallForCurrentNode(cooldownSeconds: Int = 3600) {
        let key = effectiveNodeAddress()
        var profiles = loadScanProfiles()
        let lockUntil = Date().addingTimeInterval(TimeInterval(cooldownSeconds)).timeIntervalSince1970
        profiles[key] = ScanProfile(lastGoodPar: baselinePar, lastGoodBatch: baselineBatch, lockedUntil: lockUntil)
        saveScanProfiles(profiles)
    }

    // Record a good tuning (e.g., after smooth progress); clears any lock
    @MainActor
    static func recordGoodTuningForCurrentNode(par: Int, batch: Int) {
        let key = effectiveNodeAddress()
        var profiles = loadScanProfiles()
        profiles[key] = ScanProfile(lastGoodPar: max(0, par), lastGoodBatch: max(50, batch), lockedUntil: nil)
        saveScanProfiles(profiles)
    }

    /// Scan parallelism (workers). 0 disables parallel scan. Clamped to [0, 64].
    nonisolated static var scanParallelism: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsScanParKey)
        let value = (v >= 0 ? v : defaultScanPar)
        return max(0, min(value, 64))
    }

    /// Set scan parallelism (workers). 0 disables.
    @MainActor
    static func setScanParallelism(_ par: Int) {
        let clamped = max(0, min(par, 64))
        UserDefaults.standard.set(clamped, forKey: userDefaultsScanParKey)
    }

    /// Scan batch size (blocks per batch). Default is 200. Clamped to [50, 5000].
    nonisolated static var scanBatchSize: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsScanBatchKey)
        let value = (v > 0 ? v : defaultScanBatch)
        return max(50, min(value, 5000))
    }

    /// Set scan batch size (blocks per batch).
    @MainActor
    static func setScanBatchSize(_ batch: Int) {
        let clamped = max(50, min(batch, 5000))
        UserDefaults.standard.set(clamped, forKey: userDefaultsScanBatchKey)
    }

    /// Set the daemon address (persisted in UserDefaults)
    /// Must be called from MainActor context
    @MainActor
    static func setDaemonAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: userDefaultsKey)
    }

    /// Full daemon URL for HTTP requests (if needed)
    nonisolated static func daemonURL() -> String {
        return "http://\(daemonAddress)"
    }

    /// Effective node URL for WalletCoreFFI (full URL with protocol)
    /// If I2P mode is enabled, uses the configured I2P RPC address; otherwise uses clearnet daemon address.
    /// Note: If your I2P router requires an HTTP proxy, configure it via i2pHTTPProxyAddress (transport setup is handled elsewhere).
    nonisolated static func nodeURL() -> String {
        // Backward compatibility: treat nodeURL as the scanning endpoint
        return scanNodeURL()
    }
}
