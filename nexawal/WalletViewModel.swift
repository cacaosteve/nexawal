//
//  WalletViewModel.swift
//  nexawal
//
//  SwiftUI ViewModel for wallet state management
//

import Foundation
import SwiftUI
import Combine
import MoneroWalletCoreFFI

@MainActor
class WalletViewModel: ObservableObject {
    @Published var mnemonic: String = ""
    @Published var walletAddress: String = ""
    @Published var totalBalance: UInt64 = 0
    @Published var unlockedBalance: UInt64 = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isWalletOpen: Bool = false
    @Published var lastScannedHeight: UInt64 = 0
    @Published var isRefreshing: Bool = false
    
    private let walletManager = WalletManager.shared
    private let walletId = "main_wallet"
    
    /// Convert piconero to XMR
    func piconeroToXMR(_ piconero: UInt64) -> Double {
        return Double(piconero) / 1_000_000_000_000.0
    }
    
    /// Format XMR amount for display
    func formatXMR(_ amount: Double) -> String {
        if amount >= 1.0 {
            return String(format: "%.4f XMR", amount)
        } else if amount >= 0.0001 {
            return String(format: "%.6f XMR", amount)
        } else {
            return String(format: "%.12f XMR", amount)
        }
    }
    
    /// Create or import a wallet from mnemonic
    func createWallet(mnemonic: String, restoreHeight: UInt64 = 0, mainnet: Bool = true) async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Derive address first to validate mnemonic
            let address = try await WalletManager.shared.derivePrimaryAddress(mnemonic: mnemonic, mainnet: mainnet)
            
            // Open the wallet
            try await WalletManager.shared.openWallet(
                mnemonic: mnemonic,
                walletId: walletId,
                restoreHeight: restoreHeight,
                mainnet: mainnet
            )
            
            self.mnemonic = mnemonic
            self.walletAddress = address
            self.isWalletOpen = true
            
            // Initial refresh and balance fetch
            await refreshWallet()
            
        } catch {
            errorMessage = error.localizedDescription
            isWalletOpen = false
        }
        
        isLoading = false
    }
    
    /// Refresh wallet from the Monero node
    func refreshWallet() async {
        guard isWalletOpen else { return }
        
        isRefreshing = true
        errorMessage = nil
        
        do {
            let scanned = try await walletManager.refreshWallet()
            lastScannedHeight = scanned
            
            // Update balance after refresh
            let balance = try await WalletManager.shared.getBalance()
            
            totalBalance = balance.total
            unlockedBalance = balance.unlocked
            
        } catch {
            errorMessage = "Refresh failed: \(error.localizedDescription)"
        }
        
        isRefreshing = false
    }
    
    /// Update balance without refreshing (quick check)
    func updateBalance() async {
        guard isWalletOpen else { return }
        
        do {
            let balance = try await WalletManager.shared.getBalance()
            
            totalBalance = balance.total
            unlockedBalance = balance.unlocked
        } catch {
            errorMessage = "Failed to get balance: \(error.localizedDescription)"
        }
    }
    
    /// Get WalletCore version
    func getVersion() -> String {
        // getVersion() is safe to call synchronously as it doesn't access actor state
        return WalletCoreFFIClient.version()
    }
}

