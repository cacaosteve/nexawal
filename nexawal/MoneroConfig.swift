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

    /// Node URL format for WalletCoreFFI (full URL with protocol)
    /// The wallet core expects a full URL like "http://hostname:port"
    /// Safe to call from any actor context
    nonisolated static func nodeURL() -> String {
        // If daemonAddress already contains a protocol, use it as-is
        if daemonAddress.hasPrefix("http://") || daemonAddress.hasPrefix("https://") {
            return daemonAddress
        }
        // Otherwise, prepend http://
        return "http://\(daemonAddress)"
    }
}
