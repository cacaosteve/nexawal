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
    @Published var biometricsEnabled: Bool = false

    private let walletManager = WalletManager.shared
    private let walletId = "main_wallet"
    private let storage = WalletStorage.shared
    private var storedMetadata: StoredWalletMetadata?

    init() {
        Task { [weak self] in
            guard let self else { return }
            await self.loadStoredWalletOnLaunch()
        }
    }

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
    func createWallet(mnemonic: String, restoreHeight: UInt64 = 0, mainnet: Bool = true, requireBiometrics: Bool = false) async {
        isLoading = true
        errorMessage = nil

        do {
            let address = try await walletManager.derivePrimaryAddress(mnemonic: mnemonic, mainnet: mainnet)

            try await walletManager.openWallet(
                mnemonic: mnemonic,
                walletId: walletId,
                restoreHeight: restoreHeight,
                mainnet: mainnet
            )

            self.mnemonic = mnemonic
            self.walletAddress = address
            self.isWalletOpen = true
            self.biometricsEnabled = requireBiometrics
            self.lastScannedHeight = 0
            self.totalBalance = 0
            self.unlockedBalance = 0

            let metadata = StoredWalletMetadata(
                walletId: walletId,
                restoreHeight: restoreHeight,
                lastScannedHeight: 0,
                totalBalance: 0,
                unlockedBalance: 0,
                mainnet: mainnet,
                biometricsEnabled: requireBiometrics
            )

            do {
                try await storage.storeWallet(
                    mnemonic: mnemonic,
                    metadata: metadata,
                    requireBiometrics: requireBiometrics
                )
                storedMetadata = metadata
            } catch {
                let message = "Wallet opened, but persistence failed: \(error.localizedDescription)"
                print("⚠️ \(message)")
                errorMessage = message
            }

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

            let balance = try await walletManager.getBalance()

            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            await persistMetadataUpdate { metadata in
                metadata.lastScannedHeight = scanned
                metadata.totalBalance = balance.total
                metadata.unlockedBalance = balance.unlocked
            }
        } catch {
            errorMessage = "Refresh failed: \(error.localizedDescription)"
        }

        isRefreshing = false
    }

    /// Update balance without refreshing (quick check)
    func updateBalance() async {
        guard isWalletOpen else { return }

        do {
            let balance = try await walletManager.getBalance()

            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            await persistMetadataUpdate { metadata in
                metadata.totalBalance = balance.total
                metadata.unlockedBalance = balance.unlocked
            }
        } catch {
            errorMessage = "Failed to get balance: \(error.localizedDescription)"
        }
    }

    private func persistMetadataUpdate(_ update: (inout StoredWalletMetadata) -> Void) async {
        do {
            if storedMetadata == nil {
                storedMetadata = try await storage.loadMetadata()
            }
            guard var metadata = storedMetadata else { return }
            update(&metadata)
            metadata.lastUpdated = Date()
            storedMetadata = metadata
            try await storage.saveMetadataOnly(metadata)
        } catch WalletStorageError.walletNotStored {
            // Nothing to persist yet
        } catch {
            print("⚠️ Metadata persistence failed: \(error)")
        }
    }

    private func loadStoredWalletOnLaunch() async {
        do {
            guard let metadata = try await storage.loadMetadata() else {
                return
            }

            isLoading = true
            defer { isLoading = false }

            errorMessage = nil
            storedMetadata = metadata
            biometricsEnabled = metadata.biometricsEnabled

            let mnemonic = try await storage.loadMnemonic(prompt: "Authenticate to unlock NexaWal")
            let address = try await walletManager.derivePrimaryAddress(mnemonic: mnemonic, mainnet: metadata.mainnet)

            try await walletManager.openWallet(
                mnemonic: mnemonic,
                walletId: walletId,
                restoreHeight: metadata.restoreHeight,
                mainnet: metadata.mainnet
            )

            self.mnemonic = mnemonic
            self.walletAddress = address
            self.totalBalance = metadata.totalBalance
            self.unlockedBalance = metadata.unlockedBalance
            self.lastScannedHeight = metadata.lastScannedHeight
            self.isWalletOpen = true

            await refreshWallet()
        } catch let storageError as WalletStorageError {
            switch storageError {
            case .cancelled:
                errorMessage = nil
                return
            default:
                errorMessage = storageError.localizedDescription
            }
        } catch {
            print("⚠️ Failed to load stored wallet: \(error)")
        }
    }

    /// Get WalletCore version
    func getVersion() -> String {
        // getVersion() is safe to call synchronously as it doesn't access actor state
        return WalletCoreFFIClient.version()
    }
}
