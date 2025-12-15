import Foundation
import SwiftUI
import MoneroWalletCoreFFI
import Combine
import CryptoKit

@MainActor
class WalletViewModel: ObservableObject {
    // MARK: - Published properties

    @Published var mnemonic: String = ""
    @Published var walletAddress: String = ""
    @Published var totalBalance: UInt64 = 0
    @Published var unlockedBalance: UInt64 = 0

    // Transaction history (transfer-level)
    @Published var transfers: [WalletCoreFFIClient.Transfer] = []

    @Published var isLoading: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var isWalletOpen: Bool = false
    @Published var errorMessage: String?

    @Published var biometricsEnabled: Bool = false
    @Published var restoreHeight: UInt64 = 0
    @Published var lastScannedHeight: UInt64 = 0
    @Published var chainHeight: UInt64 = 0
    @Published var chainTime: UInt64 = 0
    @Published var scanBlocksPerSecond: Double = 0.0

    // MARK: - Dependencies

    private let walletManager = WalletManager.shared
    private let storage = WalletStorage.shared

    // While syncing, periodically refresh transfer history so pending/outgoing and new incoming
    // appear without requiring a manual refresh.
    private var lastTransfersPollAt: Date?
    private let transfersPollInterval: TimeInterval = 10.0

    // NexaWal currently supports a single active wallet.
    // We keep the walletId constant and *only* clear persisted data/cache via an explicit replace flow.
    private let walletId = "main_wallet"

    private var storedMetadata: StoredWalletMetadata?
    private var isMainnet: Bool = true
    private var syncStatusPollTask: Task<Void, Never>?
    private var isManualRescanInProgress: Bool = false
    private var lastPollingStatus: (chainHeight: UInt64, lastScanned: UInt64)?
    private var lastPollingUpdate: Date?
    private var pendingSyncPollRestart: Bool = false
    private let pollingStagnationInterval: TimeInterval = 5.0

    // Single-wallet behavior: track the seed we last opened to avoid accidental destructive operations.
    // NOTE: This is a privacy-preserving fingerprint (SHA256 of normalized mnemonic), not the mnemonic itself.
    private var lastOpenedMnemonicFingerprint: String?

    // While syncing, periodically refresh balance so the UI reflects incoming funds without requiring a manual refresh.
    private var lastBalancePollAt: Date?
    private let balancePollInterval: TimeInterval = 10.0

    // MARK: - Computed flags

    var syncProgress: Double {
        let tol: UInt64 = 3
        // Consider near-tip within tolerance as fully synced
        if chainHeight > 0 && lastScannedHeight + tol >= chainHeight {
            return 1.0
        }

        guard chainHeight > restoreHeight else {
            return 0.0
        }

        let clampedScanned = min(lastScannedHeight, chainHeight)
        let workSpan = chainHeight - restoreHeight
        guard workSpan > 0 else { return 0.0 }

        let completed = clampedScanned > restoreHeight ? (clampedScanned - restoreHeight) : 0
        return min(1.0, Double(completed) / Double(workSpan))
    }

    var remainingBlocks: UInt64 {
        let tol: UInt64 = 3
        let diff = chainHeight > lastScannedHeight ? (chainHeight - lastScannedHeight) : 0
        // Hide tiny residual near tip
        return diff > tol ? diff : 0
    }

    var isSynced: Bool {
        let tol: UInt64 = 3
        return chainHeight > 0 && lastScannedHeight + tol >= chainHeight
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

    /// Returns true if a wallet is persisted on device (metadata exists).
    /// This is the authoritative signal for "Replace existing wallet?" confirmations.
    func hasStoredWallet() async -> Bool {
        do {
            return (try await storage.loadMetadata()) != nil
        } catch {
            return false
        }
    }

    /// Replace the existing single wallet with a new mnemonic (destructive).
    /// Call this only after explicit user confirmation.
    func replaceWallet(
        mnemonic rawMnemonic: String,
        restoreHeight: UInt64 = 0,
        mainnet: Bool = true,
        requireBiometrics: Bool = false
    ) async {
        // Clear persisted metadata + mnemonic first
        do {
            try await storage.clearWallet()
        } catch {
            // Continue: we can still attempt to open, but stale state may require a full rescan.
            print("⚠️ Failed to clear stored wallet data during replace: \(error.localizedDescription)")
        }

        // Best-effort: clear any persisted scan cache for the (constant) walletId.
        do {
            // Need an open walletId for clearScanCache(); open is cheap and will be overwritten below anyway.
            let normalized = rawMnemonic
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if !normalized.isEmpty {
                try await walletManager.openWallet(
                    mnemonic: normalized,
                    walletId: walletId,
                    restoreHeight: restoreHeight,
                    mainnet: mainnet
                )
                try await walletManager.clearScanCache()
            }
        } catch {
            print("⚠️ Failed to clear scan cache during replace: \(error.localizedDescription)")
        }

        await createWallet(
            mnemonic: rawMnemonic,
            restoreHeight: restoreHeight,
            mainnet: mainnet,
            requireBiometrics: requireBiometrics
        )
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

    /// Create/import a wallet in the single-wallet slot.
    /// This is non-destructive: it does NOT clear any existing persisted wallet data.
    /// Use `replaceWallet(...)` when the user has explicitly confirmed replacement.
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

            // Record the active wallet fingerprint for replacement detection/telemetry (non-destructive).
            lastOpenedMnemonicFingerprint = Self.mnemonicFingerprint(normalizedMnemonic)

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

            // Always do a final balance fetch at the end of refresh so totals are correct.
            let balance = try await walletManager.getBalance()
            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            // Refresh transfer history at end of refresh (authoritative)
            // WalletManager is an actor; avoid calling actor-isolated methods from this main-actor context.
            if let rows = try? WalletCoreFFIClient.listTransfers(walletId: walletId) {
                transfers = rows
            }

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

            await persistMetadataUpdate { metadata in
                metadata.totalBalance = balance.total
                metadata.unlockedBalance = balance.unlocked
            }
        } catch {
            errorMessage = "Failed to get balance: \(error.localizedDescription)"
        }
    }

    func rescan(from height: UInt64) async {
        let trimmedMnemonic = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMnemonic.isEmpty else {
            errorMessage = "Rescan failed: mnemonic is unavailable."
            return
        }

        if isRefreshing {
            return
        }

        isManualRescanInProgress = true
        isRefreshing = true
        errorMessage = nil
        mnemonic = trimmedMnemonic
        restoreHeight = height
        lastScannedHeight = height
        chainHeight = max(chainHeight, height)
        totalBalance = 0
        unlockedBalance = 0
        startSyncStatusPolling()

        defer {
            isManualRescanInProgress = false
            stopSyncStatusPolling()
            isRefreshing = false
        }

        do {
            let status = try await walletManager.rescan(from: height)
            applySyncStatus(status)

            let balance = try await walletManager.getBalance()
            totalBalance = balance.total
            unlockedBalance = balance.unlocked

            await persistMetadataUpdate { [self] metadata in
                metadata.restoreHeight = self.restoreHeight
                metadata.lastScannedHeight = self.lastScannedHeight
                metadata.chainHeight = self.chainHeight
                metadata.totalBalance = self.totalBalance
                metadata.unlockedBalance = self.unlockedBalance
            }
        } catch {
            errorMessage = "Rescan failed: \(error.localizedDescription)"
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
        lastBalancePollAt = nil
        lastTransfersPollAt = nil
        syncStatusPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let status = try await self.walletManager.getSyncStatus()

                    // Update sync status (and compute scan rate) on the main actor.
                    let shouldRestart = await MainActor.run { () -> Bool in
                        self.applySyncStatus(status)
                        let now = Date()
                        let tuple = (chainHeight: status.chainHeight, lastScanned: status.lastScanned)
                        if self.lastPollingStatus?.chainHeight != tuple.chainHeight ||
                            self.lastPollingStatus?.lastScanned != tuple.lastScanned {
                            let prev = self.lastPollingStatus
                            let prevUpdate = self.lastPollingUpdate
                            if let prev = prev, let lastUpdate = prevUpdate {
                                let dt = now.timeIntervalSince(lastUpdate)
                                if dt > 0 {
                                    let db = Double(status.lastScanned) - Double(prev.lastScanned)
                                    self.scanBlocksPerSecond = max(0.0, db / dt)
                                }
                            } else {
                                self.scanBlocksPerSecond = 0.0
                            }
                            self.lastPollingStatus = tuple
                            self.lastPollingUpdate = now
                            return false
                        }
                        if !self.isSynced,
                           !self.isManualRescanInProgress,
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

                    // While syncing, refresh balances every 10 seconds so the UI updates during long scans.
                    // This is rate-limited and skipped when already synced.
                    let shouldPollBalance: Bool = await MainActor.run {
                        guard !self.isSynced else { return false }
                        let now = Date()
                        if let last = self.lastBalancePollAt {
                            return now.timeIntervalSince(last) >= self.balancePollInterval
                        }
                        return true
                    }

                    if shouldPollBalance {
                        do {
                            let balance = try await self.walletManager.getBalance()
                            await MainActor.run {
                                self.totalBalance = balance.total
                                self.unlockedBalance = balance.unlocked
                                self.lastBalancePollAt = Date()
                            }
                            await self.persistMetadataUpdate { metadata in
                                metadata.totalBalance = balance.total
                                metadata.unlockedBalance = balance.unlocked
                            }
                        } catch {
                            // Ignore intermittent balance fetch errors during sync; final refresh will update balances.
                        }
                    }

                    // While syncing, refresh transfer history every 10 seconds (rate-limited) so the UI shows
                    // newly discovered incoming transfers and pending outgoing items without manual refresh.
                    let shouldPollTransfers: Bool = await MainActor.run {
                        guard !self.isSynced else { return false }
                        let now = Date()
                        if let last = self.lastTransfersPollAt {
                            return now.timeIntervalSince(last) >= self.transfersPollInterval
                        }
                        return true
                    }

                    if shouldPollTransfers {
                        do {
                            let rows = try await MainActor.run { () -> [WalletCoreFFIClient.Transfer]? in
                                // WalletManager is an actor; avoid calling actor-isolated methods from this main-actor block.
                                return try? WalletCoreFFIClient.listTransfers(walletId: self.walletId)
                            }
                            if let rows {
                                await MainActor.run {
                                    self.transfers = rows
                                    self.lastTransfersPollAt = Date()
                                }
                            }
                        } catch {
                            // Ignore intermittent transfer fetch errors during sync; final refresh will update transfers.
                        }
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
                    self.lastBalancePollAt = nil
                    self.lastTransfersPollAt = nil
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
        let normalizedRestoreHeight = min(status.restoreHeight, normalizedChainHeight)
        let normalizedLastScanned = min(max(status.lastScanned, normalizedRestoreHeight), normalizedChainHeight)

        chainHeight = normalizedChainHeight
        if status.chainTime > 0 {
            chainTime = status.chainTime
        }
        restoreHeight = normalizedRestoreHeight
        lastScannedHeight = normalizedLastScanned
    }

    private func applyMetadataSnapshot(_ metadata: StoredWalletMetadata) async {
        var snapshot = metadata
        let normalizedChainHeight = max(snapshot.chainHeight, snapshot.lastScannedHeight, snapshot.restoreHeight)
        let normalizedRestoreHeight = min(snapshot.restoreHeight, normalizedChainHeight)
        let normalizedLastScanned = min(max(snapshot.lastScannedHeight, normalizedRestoreHeight), normalizedChainHeight)

        snapshot.chainHeight = normalizedChainHeight
        snapshot.restoreHeight = normalizedRestoreHeight
        snapshot.lastScannedHeight = normalizedLastScanned

        storedMetadata = snapshot

        restoreHeight = normalizedRestoreHeight
        chainHeight = normalizedChainHeight
        lastScannedHeight = normalizedLastScanned
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
            lastOpenedMnemonicFingerprint = Self.mnemonicFingerprint(mnemonic)

            let address = try await walletManager.derivePrimaryAddress(
                mnemonic: mnemonic,
                mainnet: metadata.mainnet
            )
            walletAddress = address

            // Open with the persisted restore height for this wallet.
            // If the user later replaces the seed, createWallet() will clear metadata+cache first.
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

    private static func mnemonicFingerprint(_ mnemonic: String) -> String {
        let normalized = mnemonic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
