//
//  MoneroConfig.swift
//  nexawal
//
//  Configuration for Monero node connection
//  Matches supermegamart's MoneroConfig setup
//

import Foundation

struct MoneroConfig {
    nonisolated(unsafe) static let defaultAddress = "192.168.4.137:18081"
    nonisolated(unsafe) static let userDefaultsKey = "monero_daemon_address"

    // I2P defaults and keys
    nonisolated(unsafe) static let defaultI2PRPCAddress = "cvxtgqjorfif6i5x5fenys6fj7hzddbgavpyutps6gphywnlklqa.b32.i2p:18089"
    nonisolated(unsafe) static let userDefaultsI2PModeKey = "monero_i2p_mode"
    nonisolated(unsafe) static let userDefaultsI2PRPCKey = "monero_i2p_rpc_address"
    nonisolated(unsafe) static let userDefaultsI2PProxyKey = "monero_i2p_http_proxy"
    // Gap limit key and default
    nonisolated(unsafe) static let userDefaultsGapLimitKey = "monero_gap_limit"
    nonisolated(unsafe) static let defaultGapLimit: UInt32 = 50
    // Scan tuning keys and defaults
    nonisolated(unsafe) static let userDefaultsScanParKey = "walletcore_scan_par"
    nonisolated(unsafe) static let userDefaultsScanBatchKey = "walletcore_scan_batch"
    nonisolated(unsafe) static let defaultScanPar: Int = 0
    nonisolated(unsafe) static let defaultScanBatch: Int = 200

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
        let address = useI2P ? i2pRPCAddress : daemonAddress
        // If the address already contains a protocol, use it as-is
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            return address
        }
        // Otherwise, prepend http://
        return "http://\(address)"
    }
}
