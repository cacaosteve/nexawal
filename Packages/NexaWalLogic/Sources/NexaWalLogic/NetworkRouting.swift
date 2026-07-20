import Foundation

/// Pure network-policy helpers shared by Settings / WalletManager (no UserDefaults).
public enum NetworkRouting: Sendable {
    public enum Policy: String, Sendable {
        case clearnet
        case i2p
        case hybrid

        public static func fromRaw(_ raw: String?) -> Policy {
            switch raw?.lowercased() {
            case "i2p": return .i2p
            case "hybrid": return .hybrid
            default: return .clearnet
            }
        }
    }

    public static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasSuffix(":443") {
            return "https://\(trimmed)"
        }
        return "http://\(trimmed)"
    }

    public static func scanNodeAddress(policy: Policy, clearnetNodeAddress: String, i2pRPCAddress: String) -> String {
        switch policy {
        case .clearnet, .hybrid:
            return clearnetNodeAddress
        case .i2p:
            return i2pRPCAddress
        }
    }

    public static func broadcastNodeAddress(policy: Policy, clearnetNodeAddress: String, i2pRPCAddress: String) -> String {
        switch policy {
        case .clearnet:
            return clearnetNodeAddress
        case .i2p, .hybrid:
            return i2pRPCAddress
        }
    }

    public static func scanNodeURL(policy: Policy, clearnetNodeURL: String, i2pRPCAddress: String) -> String {
        switch policy {
        case .clearnet, .hybrid:
            return clearnetNodeURL
        case .i2p:
            return normalizeURL(i2pRPCAddress)
        }
    }

    public static func broadcastNodeURL(policy: Policy, clearnetNodeURL: String, i2pRPCAddress: String) -> String {
        switch policy {
        case .clearnet:
            return clearnetNodeURL
        case .i2p, .hybrid:
            return normalizeURL(i2pRPCAddress)
        }
    }

    /// True when daemon RPC for this policy should go through the I2P HTTP proxy.
    public static func shouldUseI2PHTTPProxy(
        policy: Policy,
        proxyConfigured: Bool,
        forBroadcast: Bool
    ) -> Bool {
        guard proxyConfigured else { return false }
        switch policy {
        case .clearnet: return false
        case .i2p: return true
        case .hybrid: return forBroadcast
        }
    }
}
