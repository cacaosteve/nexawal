//
//  WalletManager.swift
//  nexawal
//
//  Manages Monero wallet operations using MoneroWalletCoreFFI
//

import Foundation
import MoneroWalletCoreFFI

enum WalletError: LocalizedError {
    case invalidMnemonic
    case walletOpenFailed(String)
    case refreshFailed(String)
    case balanceFailed(String)
    case addressDerivationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidMnemonic:
            return "Invalid mnemonic phrase. Must be 25 words."
        case .walletOpenFailed(let msg):
            return "Failed to open wallet: \(msg)"
        case .refreshFailed(let msg):
            return "Failed to refresh wallet: \(msg)"
        case .balanceFailed(let msg):
            return "Failed to get balance: \(msg)"
        case .addressDerivationFailed(let msg):
            return "Failed to derive address: \(msg)"
        }
    }
}

actor WalletManager {
    static let shared = WalletManager()
    
    private var currentWalletId: String?
    private var cachedBalance: (total: UInt64, unlocked: UInt64)?
    
    private init() {}
    
    /// Open or create a wallet from a mnemonic phrase
    func openWallet(mnemonic: String, walletId: String = "main_wallet", restoreHeight: UInt64 = 0, mainnet: Bool = true) throws {
        // Validate mnemonic (should be 25 words)
        let words = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces)
        guard words.count == 25 else {
            throw WalletError.invalidMnemonic
        }
        
        do {
            try WalletCoreFFIClient.openWalletFromMnemonic(
                walletId: walletId,
                mnemonic: mnemonic.trimmingCharacters(in: .whitespacesAndNewlines),
                restoreHeight: restoreHeight,
                mainnet: mainnet
            )
            currentWalletId = walletId
            cachedBalance = nil // Clear cached balance
        } catch {
            throw WalletError.walletOpenFailed(error.localizedDescription)
        }
    }
    
    /// Refresh the wallet against the Monero node
    func refreshWallet() async throws -> UInt64 {
        guard let walletId = currentWalletId else {
            throw WalletError.refreshFailed("No wallet is currently open")
        }
        
        let nodeURL = MoneroConfig.nodeURL()
        
        // Try with the configured node URL first
        do {
            let lastScanned = try await Task.detached {
                try WalletCoreFFIClient.refreshWallet(
                    walletId: walletId,
                    nodeURL: nodeURL
                )
            }.value
            // Clear cached balance after refresh
            cachedBalance = nil
            return lastScanned
        } catch let nodeError {
            // If refresh fails with nodeURL, try without it (uses wallet core default)
            // This helps if the configured node is unreachable
            do {
                print("⚠️ Refresh with nodeURL '\(nodeURL)' failed: \(nodeError.localizedDescription)")
                print("⚠️ Attempting refresh without nodeURL (using wallet core default)...")
                let lastScanned = try await Task.detached {
                    try WalletCoreFFIClient.refreshWallet(
                        walletId: walletId,
                        nodeURL: nil
                    )
                }.value
                cachedBalance = nil
                print("✅ Refresh succeeded using wallet core default node")
                return lastScanned
            } catch let defaultError {
                let detailedError = """
                Failed to refresh wallet.
                
                Attempted node: \(nodeURL)
                Error with configured node: \(nodeError.localizedDescription)
                Error with default node: \(defaultError.localizedDescription)
                
                Possible issues:
                - Node at \(nodeURL) is not reachable from this device
                - Network connectivity issue
                - Node is not running or not accepting connections
                - Check Settings to verify node address is correct
                - If using simulator, ensure it can reach the network (192.168.x.x addresses may not work)
                """
                throw WalletError.refreshFailed(detailedError)
            }
        }
    }
    
    /// Get the wallet balance (total and unlocked in piconero)
    func getBalance() throws -> (total: UInt64, unlocked: UInt64) {
        guard let walletId = currentWalletId else {
            throw WalletError.balanceFailed("No wallet is currently open")
        }
        
        // Return cached balance if available
        if let cached = cachedBalance {
            return cached
        }
        
        do {
            let balance = try WalletCoreFFIClient.getBalance(walletId: walletId)
            cachedBalance = balance
            return balance
        } catch {
            throw WalletError.balanceFailed(error.localizedDescription)
        }
    }
    
    /// Derive the primary address from the current wallet's mnemonic
    /// Note: This requires storing the mnemonic, which we'll handle in the ViewModel
    func derivePrimaryAddress(mnemonic: String, mainnet: Bool = true) throws -> String {
        do {
            return try WalletCoreFFIClient.derivePrimaryAddressFromMnemonic(mnemonic, mainnet: mainnet)
        } catch {
            throw WalletError.addressDerivationFailed(error.localizedDescription)
        }
    }
    
    /// Get the WalletCore version
    func getVersion() -> String {
        return WalletCoreFFIClient.version()
    }
    
    /// Check if a wallet is currently open
    func isWalletOpen() -> Bool {
        return currentWalletId != nil
    }
    
    /// Get the current wallet ID
    func getCurrentWalletId() -> String? {
        return currentWalletId
    }
}

