import Foundation
import SwiftUI
import MoneroWalletCoreFFI
import Combine

@MainActor
class WalletViewModel: ObservableObject {
    // MARK: - Published properties

    @Published var mnemonic: String = ""
    @Published var walletAddress: String = ""
    @Published var totalBalance: UInt64 = 0
    @Published var unlockedBalance: UInt64 = 0

    @Published var isLoading: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var isWalletOpen: Bool = false
    @Published var errorMessage: String?

    @Published var biometricsEnabled: Bool = false
    @Published var restoreHeight: UInt64 = 0
    @Published var lastScannedHeight: UInt64 = 0
    @Published var chainHeight: UInt64 = 0
    @Published var chainTime: UInt64 = 0

    // MARK: - Dependencies

    private let walletManager = WalletManager.shared
    private let storage = WalletStorage.shared
    private let walletId = "main_wallet"

    private var storedMetadata: StoredWalletMetadata?
    private var isMainnet: Bool = true
    private var syncStatusPollTask: Task<Void, Never>?
    private var lastPollingStatus: (chainHeight: UInt64, lastScanned: UInt64)?
    private var lastPollingUpdate: Date?
    private var pendingSyncPollRestart: Bool = false
    private let pollingStagnationInterval: TimeInterval = 5.0

    // MARK: - Computed flags

    var syncProgress: Double {
        guard chainHeight > restoreHeight else {
            return chainHeight > 0 && lastScannedHeight >= chainHeight ? 1.0 : 0.0
        }

        let clampedScanned = min(lastScannedHeight, chainHeight)
        let workSpan = chainHeight - restoreHeight
        guard workSpan > 0 else { return 0.0 }

        let completed = clampedScanned > restoreHeight ? (clampedScanned - restoreHeight) : 0
        return min(1.0, Double(completed) / Double(workSpan))
    }

    var remainingBlocks: UInt64 {
        chainHeight > lastScannedHeight ? (chainHeight - lastScannedHeight) : 0
    }

    var isSynced: Bool {
        chainHeight > 0 && lastScannedHeight >= chainHeight
    }

    // MARK: - Init

    init() {
        Task { [weak self] in
            await self?.loadStoredWalletOnLaunch()
        }
    }

    // MARK: - Public API

    func piconeroToXMR(_ piconero: UInt64) -> Double {
        Double(piconero) / 1_000_000_000_000.0
    }

    func formatXMR(_ amount: Double) -> String {
        switch amount {
        case let value where value >= 1.0:
            return String(format: "%.4f XMR", value)
        case let value where value >= 0.0001:
            return String(format: "%.6f XMR", value)
        default:
            return String(format: "%.12f XMR", amount)
        }
    }

    func createWallet(
        mnemonic rawMnemonic: String,
        restoreHeight: UInt64 = 0,
        mainnet: Bool = true,
        requireBiometrics: Bool = false
    ) async {
        let normalizedMnemonic = rawMnemonic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !normalizedMnemonic.isEmpty else {
            errorMessage = "Mnemonic cannot be empty."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let address = try await walletManager.derivePrimaryAddress(
                mnemonic: normalizedMnemonic,
                mainnet: mainnet
            )

            try await walletManager.openWallet(
                mnemonic: normalizedMnemonic,
                walletId: walletId,
                restoreHeight: restoreHeight,
                mainnet: mainnet
            )

            isMainnet = mainnet
            mnemonic = normalizedMnemonic
            walletAddress = address
            biometricsEnabled = requireBiometrics
            self.restoreHeight = restoreHeight
            lastScannedHeight = restoreHeight
            chainHeight = restoreHeight
            chainTime = 0
            totalBalance = 0
            unlockedBalance = 0
            isWalletOpen = true

            let metadata = StoredWalletMetadata(
                walletId: walletId,
                restoreHeight: restoreHeight,
                lastScannedHeight: restoreHeight,
                chainHeight: restoreHeight,
                totalBalance: 0,
                unlockedBalance: 0,
                mainnet: mainnet,
                biometricsEnabled: requireBiometrics
            )
            storedMetadata = metadata
            do {
                try await storage.storeWallet(
                    mnemonic: normalizedMnemonic,
                    metadata: metadata,
                    requireBiometrics: requireBiometrics
                )
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

    func refreshWallet() async {
        guard isWalletOpen else { return }

        isRefreshing = true
        errorMessage = nil
        startSyncStatusPolling()
        defer {
            stopSyncStatusPolling()
            isRefreshing = false
        }

        do {
            let status = try await walletManager.refreshWallet()
            applySyncStatus(status)

            let balance = try await walletManager.getBalance()
            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            await persistMetadataUpdate()
        } catch {
            errorMessage = "Refresh failed: \(error.localizedDescription)"
        }
    }

    /// Update balance without refreshing (quick check)
    func updateBalance() async {
        guard isWalletOpen else { return }

        do {
            if let status = try? await walletManager.getSyncStatus() {
                applySyncStatus(status)
            }

            let balance = try await walletManager.getBalance()

            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            await persistMetadataUpdate()
        } catch {
            errorMessage = "Failed to get balance: \(error.localizedDescription)"
        }
    }

    func getVersion() -> String {
        WalletCoreFFIClient.version()
    }

    // MARK: - Private helpers

    private func startSyncStatusPolling() {
        syncStatusPollTask?.cancel()
        pendingSyncPollRestart = false
        lastPollingStatus = (chainHeight: chainHeight, lastScanned: lastScannedHeight)
        lastPollingUpdate = Date()
        syncStatusPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let status = try await self.walletManager.getSyncStatus()
                    let shouldRestart = await MainActor.run { () -> Bool in
                        self.applySyncStatus(status)
                        let now = Date()
                        let tuple = (chainHeight: status.chainHeight, lastScanned: status.lastScanned)
                        if self.lastPollingStatus?.chainHeight != tuple.chainHeight ||
                            self.lastPollingStatus?.lastScanned != tuple.lastScanned {
                            self.lastPollingStatus = tuple
                            self.lastPollingUpdate = now
                            return false
                        }
                        if !self.isSynced,
                           let lastUpdate = self.lastPollingUpdate,
                           now.timeIntervalSince(lastUpdate) > self.pollingStagnationInterval {
                            self.lastPollingUpdate = now
                            self.pendingSyncPollRestart = true
                            return true
                        }
                        return false
                    }
                    if shouldRestart {
                        break
                    }
                } catch {
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            await MainActor.run {
                if self.pendingSyncPollRestart {
                    self.pendingSyncPollRestart = false
                    self.syncStatusPollTask = nil
                    self.startSyncStatusPolling()
                } else {
                    self.syncStatusPollTask = nil
                    self.lastPollingStatus = nil
                    self.lastPollingUpdate = nil
                }
            }
        }
    }

    private func stopSyncStatusPolling() {
        syncStatusPollTask?.cancel()
        syncStatusPollTask = nil
        lastPollingStatus = nil
        lastPollingUpdate = nil
        pendingSyncPollRestart = false
    }

    private func applySyncStatus(_ status: WalletCoreFFIClient.SyncStatus) {
        let normalizedChainHeight = max(status.chainHeight, status.restoreHeight, status.lastScanned)
        let normalizedLastScanned = min(max(status.lastScanned, status.restoreHeight), normalizedChainHeight)

        chainHeight = max(chainHeight, normalizedChainHeight)
        if status.chainTime > 0 {
            chainTime = status.chainTime
        }
        restoreHeight = max(restoreHeight, status.restoreHeight)
        lastScannedHeight = min(max(lastScannedHeight, normalizedLastScanned), chainHeight)
    }

    private func applyMetadataSnapshot(_ metadata: StoredWalletMetadata) async {
        var snapshot = metadata
        let normalizedChainHeight = max(snapshot.chainHeight, snapshot.lastScannedHeight, snapshot.restoreHeight)
        let normalizedLastScanned = min(max(snapshot.lastScannedHeight, snapshot.restoreHeight), normalizedChainHeight)

        snapshot.chainHeight = normalizedChainHeight
        snapshot.lastScannedHeight = normalizedLastScanned

        storedMetadata = snapshot

        restoreHeight = max(restoreHeight, snapshot.restoreHeight)
        chainHeight = max(chainHeight, snapshot.chainHeight)
        lastScannedHeight = min(max(lastScannedHeight, snapshot.lastScannedHeight), chainHeight)
        totalBalance = snapshot.totalBalance
        unlockedBalance = snapshot.unlockedBalance
        biometricsEnabled = snapshot.biometricsEnabled
        chainTime = 0
        isMainnet = snapshot.mainnet

        do {
            try await storage.saveMetadataOnly(snapshot)
        } catch WalletStorageError.walletNotStored {
            // Ignore: nothing persisted yet.
        } catch {
            print("⚠️ Failed to persist normalized metadata: \(error)")
        }
    }

    private func persistMetadataUpdate(_ mutate: ((inout StoredWalletMetadata) -> Void)? = nil) async {
        do {
            if storedMetadata == nil {
                storedMetadata = try await storage.loadMetadata()
            }
            guard var metadata = storedMetadata else { return }

            mutate?(&metadata)
            metadata.totalBalance = totalBalance
            metadata.unlockedBalance = unlockedBalance
            metadata.lastScannedHeight = lastScannedHeight
            metadata.restoreHeight = restoreHeight
            metadata.chainHeight = max(chainHeight, max(lastScannedHeight, restoreHeight))
            metadata.biometricsEnabled = biometricsEnabled
            metadata.mainnet = isMainnet
            metadata.lastUpdated = Date()

            storedMetadata = metadata
            try await storage.saveMetadataOnly(metadata)
        } catch WalletStorageError.walletNotStored {
            // Nothing to persist yet.
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
            errorMessage = nil
            await applyMetadataSnapshot(metadata)

            let mnemonic = try await storage.loadMnemonic(prompt: "Authenticate to unlock NexaWal")
            self.mnemonic = mnemonic

            let address = try await walletManager.derivePrimaryAddress(
                mnemonic: mnemonic,
                mainnet: metadata.mainnet
            )
            walletAddress = address

            try await walletManager.openWallet(
                mnemonic: mnemonic,
                walletId: walletId,
                restoreHeight: metadata.restoreHeight,
                mainnet: metadata.mainnet
            )

            isWalletOpen = true

            if let status = try? await walletManager.getSyncStatus() {
                applySyncStatus(status)
                await persistMetadataUpdate()
            }

            await refreshWallet()
        } catch let storageError as WalletStorageError {
            switch storageError {
            case .cancelled:
                errorMessage = nil
            default:
                errorMessage = storageError.localizedDescription
            }
        } catch {
            print("⚠️ Failed to load stored wallet: \(error)")
        }

        isLoading = false
    }
}
