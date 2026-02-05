import Foundation
import Darwin

// MoneroConfig — simplified to wallet2-like defaults.
// - Only keeps node address, gap limits, account lookahead, and basic network policy.
// - Scan/bulk tuning knobs remain as no-ops/stored prefs for UI compatibility but do not enforce behavior.
// - Logging is controlled by the caller; no automatic env churn here.
struct MoneroConfig {

    // MARK: - Constants / Defaults
    nonisolated static let defaultAddress = "127.0.0.1:18081"
    nonisolated static let userDefaultsKey = "monero_daemon_address"

    // I2P defaults and keys (kept for UI compatibility)
    nonisolated static let defaultI2PRPCAddress = "cvxtgqjorfif6i5x5fenys6fj7hzddbgavpyutps6gphywnlklqa.b32.i2p:18081"
    nonisolated static let userDefaultsI2PModeKey = "monero_i2p_mode"
    nonisolated static let userDefaultsI2PRPCKey = "monero_i2p_rpc_address"
    nonisolated static let userDefaultsI2PProxyKey = "monero_i2p_http_proxy"

    // Gap limits
    nonisolated static let userDefaultsGapLimitKey = "monero_gap_limit"
    nonisolated static let defaultGapLimit: UInt32 = 50
    nonisolated static let userDefaultsAccountGapKey = "walletcore_account_gap"
    nonisolated static let defaultAccountGap: Int = 1

    // Network policy (kept minimal: clearnet / i2p / hybrid)
    nonisolated static let userDefaultsNetworkPolicyKey = "monero_network_policy"
    nonisolated static let defaultNetworkPolicyRaw = "clearnet"
    enum NetworkPolicy: String {
        case clearnet
        case i2p
        case hybrid
    }

    // Scan mode (UI compatibility; no behavior impact here)
    nonisolated static let userDefaultsScanModeKey = "monero_scan_mode"
    nonisolated static let defaultScanModeRaw = "auto"
    enum ScanMode: String {
        case auto
        case manual
    }

    // Scan tuning (UI compatibility; wallet2 baseline leaves these unused)
    nonisolated static let userDefaultsScanParKey = "walletcore_scan_par"
    nonisolated static let userDefaultsScanBatchKey = "walletcore_scan_batch"
    nonisolated static let defaultScanPar: Int = 0
    nonisolated static let defaultScanBatch: Int = 200

    // Bulk toggle (UI compatibility; core defaults take precedence)
    nonisolated static let userDefaultsBulkBinFetchKey = "walletcore_bulk_bin_fetch"
    nonisolated static let defaultBulkBinFetchEnabled: Bool = true

    // Wallet2 bulk lockout (kept as stubs to avoid crashes if called)
    nonisolated private static let userDefaultsWallet2LockoutsKey = "monero_wallet2_bulk_lockouts_v1"
    nonisolated private static let wallet2LockoutDefaultSeconds: TimeInterval = 60 * 30

    enum WalletError: Error {
        case invalidAddress
        case invalidGapLimit
        case invalidRestoreHeight
    }

    // MARK: - Network policy
    nonisolated static var networkPolicy: NetworkPolicy {
        let raw = UserDefaults.standard.string(forKey: userDefaultsNetworkPolicyKey) ?? defaultNetworkPolicyRaw
        return NetworkPolicy(rawValue: raw) ?? .clearnet
    }

    @MainActor
    static func setNetworkPolicy(_ policy: NetworkPolicy) {
        UserDefaults.standard.set(policy.rawValue, forKey: userDefaultsNetworkPolicyKey)
    }

    // MARK: - Node address helpers
    nonisolated static var daemonAddress: String {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), !saved.isEmpty {
            return saved
        }
        return defaultAddress
    }

    @MainActor
    static func setDaemonAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: userDefaultsKey)
    }

    private nonisolated static func urlFromAddress(_ address: String) -> String {
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            return address
        }
        return "http://\(address)"
    }

    nonisolated static func scanNodeAddress() -> String {
        switch networkPolicy {
        case .clearnet, .hybrid:
            return daemonAddress
        case .i2p:
            return i2pRPCAddress
        }
    }

    nonisolated static func broadcastNodeAddress() -> String {
        switch networkPolicy {
        case .clearnet:
            return daemonAddress
        case .i2p, .hybrid:
            return i2pRPCAddress
        }
    }

    nonisolated static func scanNodeURL() -> String {
        // Apply account lookahead for the core.
        setenv("WALLETCORE_ACCOUNT_GAP", "\(accountGap)", 1)
        return urlFromAddress(scanNodeAddress())
    }

    nonisolated static func broadcastNodeURL() -> String {
        urlFromAddress(broadcastNodeAddress())
    }

    // MARK: - I2P settings (UI compatibility)
    nonisolated static var useI2P: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsI2PModeKey)
    }

    @MainActor
    static func setUseI2P(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsI2PModeKey)
    }

    nonisolated static var i2pRPCAddress: String {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsI2PRPCKey), !saved.isEmpty {
            return saved
        }
        return defaultI2PRPCAddress
    }

    @MainActor
    static func setI2PRPCAddress(_ address: String) {
        UserDefaults.standard.set(address, forKey: userDefaultsI2PRPCKey)
    }

    nonisolated static var i2pHTTPProxyAddress: String? {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsI2PProxyKey), !saved.isEmpty {
            return saved
        }
        return nil
    }

    @MainActor
    static func setI2PHTTPProxyAddress(_ address: String?) {
        if let addr = address, !addr.isEmpty {
            UserDefaults.standard.set(addr, forKey: userDefaultsI2PProxyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsI2PProxyKey)
        }
    }

    // MARK: - Gap limits
    nonisolated static var gapLimit: UInt32 {
        let v = UserDefaults.standard.integer(forKey: userDefaultsGapLimitKey)
        let value = (v > 0 ? v : Int(defaultGapLimit))
        let clamped = max(1, min(value, 100_000))
        return UInt32(clamped)
    }

    @MainActor
    static func setGapLimit(_ limit: UInt32) {
        let clamped = min(max(limit, 1), 100_000)
        UserDefaults.standard.set(Int(clamped), forKey: userDefaultsGapLimitKey)
    }

    nonisolated static var accountGap: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsAccountGapKey)
        let value = (v > 0 ? v : defaultAccountGap)
        return max(1, min(value, 1_000))
    }

    @MainActor
    static func setAccountGap(_ gap: Int) {
        let clamped = max(1, min(gap, 1_000))
        UserDefaults.standard.set(clamped, forKey: userDefaultsAccountGapKey)
    }

    // MARK: - Scan mode/tuning (UI compatibility; no-op defaults)
    nonisolated static var scanMode: ScanMode {
        let raw = UserDefaults.standard.string(forKey: userDefaultsScanModeKey) ?? defaultScanModeRaw
        return ScanMode(rawValue: raw) ?? .auto
    }

    @MainActor
    static func setScanMode(_ mode: ScanMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsScanModeKey)
    }

    nonisolated static var scanParallelism: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsScanParKey)
        return max(0, min(v == 0 ? defaultScanPar : v, 64))
    }

    @MainActor
    static func setScanParallelism(_ par: Int) {
        let clamped = max(0, min(par, 64))
        UserDefaults.standard.set(clamped, forKey: userDefaultsScanParKey)
    }

    nonisolated static var scanBatchSize: Int {
        let v = UserDefaults.standard.integer(forKey: userDefaultsScanBatchKey)
        return max(50, min(v == 0 ? defaultScanBatch : v, 5000))
    }

    @MainActor
    static func setScanBatchSize(_ batch: Int) {
        let clamped = max(50, min(batch, 5000))
        UserDefaults.standard.set(clamped, forKey: userDefaultsScanBatchKey)
    }

    nonisolated static var bulkBinFetchEnabled: Bool {
        UserDefaults.standard.object(forKey: userDefaultsBulkBinFetchKey) as? Bool ?? defaultBulkBinFetchEnabled
    }

    @MainActor
    static func setBulkBinFetchEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsBulkBinFetchKey)
    }

    // Feather-like baseline: just return current par/batch values
    nonisolated static func chooseTuningForCurrentNode() -> (par: Int, batch: Int) {
        (scanParallelism, scanBatchSize)
    }

    // MARK: - Wallet2 bulk lockout (stubbed, kept for API compatibility)
    nonisolated private static func wallet2LockoutNodeKey() -> String {
        effectiveNodeAddress()
    }

    nonisolated private static func loadWallet2Lockouts() -> [String: TimeInterval] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsWallet2LockoutsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: TimeInterval].self, from: data)) ?? [:]
    }

    @MainActor
    private static func saveWallet2Lockouts(_ map: [String: TimeInterval]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: userDefaultsWallet2LockoutsKey)
        }
    }

    nonisolated static func isWallet2BulkLockedOutForCurrentNode(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let key = wallet2LockoutNodeKey()
        let until = loadWallet2Lockouts()[key] ?? 0
        return until > now
    }

    @MainActor
    static func lockOutWallet2BulkForCurrentNode(seconds: TimeInterval = wallet2LockoutDefaultSeconds) {
        let key = wallet2LockoutNodeKey()
        var map = loadWallet2Lockouts()
        let until = Date().addingTimeInterval(seconds).timeIntervalSince1970
        map[key] = until
        saveWallet2Lockouts(map)
    }

    @MainActor
    static func clearWallet2BulkLockoutForCurrentNode() {
        let key = wallet2LockoutNodeKey()
        var map = loadWallet2Lockouts()
        map.removeValue(forKey: key)
        saveWallet2Lockouts(map)
    }

    // MARK: - Utilities
    nonisolated static func effectiveNodeAddress() -> String {
        scanNodeAddress()
    }

    nonisolated static func isDeterministicWallet2DecodeFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("getblocks.bin decode failed in field 'blocks'")
            || m.contains("typed-array elem_type empty appears packed/unsupported")
            || m.contains("marker does not match expected marker")
            || m.contains("data has object with more fields than the maximum allowed")
    }
}
