import Foundation
import SwiftUI
import MoneroWalletCoreFFI
import Combine
import CryptoKit

// Receive subaddresses (account 0)
typealias ReceiveSubaddressEntry = StoredSubaddressEntry

@MainActor
class WalletViewModel: ObservableObject {
    // MARK: - Published properties

    @Published var mnemonic: String = ""
    @Published var walletAddress: String = ""
    @Published var totalBalance: UInt64 = 0
    @Published var unlockedBalance: UInt64 = 0

    // Transaction history (transfer-level)
    @Published var transfers: [WalletCoreFFIClient.Transfer] = []

    // Receive subaddresses (account 0)
    @Published var receiveSubaddresses: [ReceiveSubaddressEntry] = []
    @Published var selectedReceiveSubaddressIndex: UInt32 = 0

    @Published var isLoading: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var isWalletOpen: Bool = false
    @Published var errorMessage: String?

    // Keep a handle to the in-flight refresh so the UI can cancel it explicitly.
    private var refreshTask: Task<Void, Never>?

    @Published var biometricsEnabled: Bool = false
    @Published var restoreHeight: UInt64 = 0
    @Published var lastScannedHeight: UInt64 = 0
    @Published var chainHeight: UInt64 = 0
    @Published var chainTime: UInt64 = 0
    @Published var scanBlocksPerSecond: Double = 0.0
    @Published var balanceIsStaleWhileSyncing: Bool = false

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
    private var scanRateWindowStart: Date?
    private var scanRateWindowScanned: UInt64?
    private var lastScanProgressAt: Date?
    private var pendingSyncPollRestart: Bool = false
    private let pollingStagnationInterval: TimeInterval = 5.0
    private var needsRefreshRetryOnNextActive: Bool = false

    // Single-wallet behavior: track the seed we last opened to avoid accidental destructive operations.
    // NOTE: This is a privacy-preserving fingerprint (SHA256 of normalized mnemonic), not the mnemonic itself.
    private var lastOpenedMnemonicFingerprint: String?

    // While syncing, periodically refresh balance so the UI reflects incoming funds without requiring a manual refresh.
    private var lastBalancePollAt: Date?
    private let balancePollInterval: TimeInterval = 10.0

    // MARK: - Computed flags

    private var hasObservedNetworkTip: Bool {
        chainHeight > restoreHeight || chainTime > 0
    }

    var syncProgress: Double {
        let tol: UInt64 = 3
        guard hasObservedNetworkTip else {
            return 0.0
        }
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
        guard hasObservedNetworkTip else {
            return 0
        }
        let tol: UInt64 = 3
        let diff = chainHeight > lastScannedHeight ? (chainHeight - lastScannedHeight) : 0
        // Hide tiny residual near tip
        return diff > tol ? diff : 0
    }

    var isSynced: Bool {
        guard hasObservedNetworkTip else {
            return false
        }
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

    private func formatPiconero(_ piconero: UInt64, decimals: Int) -> String {
        let clampedDecimals = min(max(decimals, 0), 12)
        let whole = piconero / 1_000_000_000_000
        let fractional = piconero % 1_000_000_000_000

        if clampedDecimals == 0 {
            return "\(whole) XMR"
        }

        let trimFactor = (0..<(12 - clampedDecimals)).reduce(UInt64(1)) { partial, _ in
            partial * 10
        }
        let fractionalScaled = fractional / trimFactor
        let fractionalString = String(format: "%0*llu", clampedDecimals, fractionalScaled)
        return "\(whole).\(fractionalString) XMR"
    }

    func formatDisplayPiconero(_ piconero: UInt64) -> String {
        formatPiconero(piconero, decimals: 6)
    }

    func formatExactPiconero(_ piconero: UInt64) -> String {
        formatPiconero(piconero, decimals: 12)
    }

    func biometricAvailability() async -> (available: Bool, enrolled: Bool) {
        await storage.biometricAvailability()
    }

    func unlockStoredWallet() async {
        await loadStoredWalletOnLaunch()
    }

    func authenticateForSensitiveAction(prompt: String) async throws {
        try await storage.evaluateBiometricsIfNeeded(prompt: prompt)
    }

    func updateBiometricProtection(enabled: Bool) async {
        guard let metadata = storedMetadata else {
            biometricsEnabled = enabled
            return
        }
        guard !mnemonic.isEmpty else {
            errorMessage = "Wallet must be unlocked before changing biometric protection."
            return
        }

        do {
            let updatedMetadata = StoredWalletMetadata(
                walletId: metadata.walletId,
                restoreHeight: metadata.restoreHeight,
                lastScannedHeight: metadata.lastScannedHeight,
                chainHeight: metadata.chainHeight,
                totalBalance: metadata.totalBalance,
                unlockedBalance: metadata.unlockedBalance,
                mainnet: metadata.mainnet,
                biometricsEnabled: enabled,
                creationDate: metadata.creationDate,
                lastUpdated: Date()
            )
            try await storage.storeWallet(
                mnemonic: mnemonic,
                metadata: updatedMetadata,
                requireBiometrics: enabled
            )
            storedMetadata = updatedMetadata
            biometricsEnabled = enabled
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Derive the receive address for (account 0, selected subaddress minor).
    /// Falls back to the primary address if derivation fails.
    func currentReceiveAddress() -> String {
        guard !mnemonic.isEmpty else { return walletAddress }
        do {
            return try WalletCoreFFIClient.deriveSubaddressFromMnemonic(
                mnemonic,
                accountIndex: 0,
                subaddressIndex: selectedReceiveSubaddressIndex,
                mainnet: isMainnet
            )
        } catch {
            return walletAddress
        }
    }

    /// Reload the persisted subaddress book and publish it.
    func loadReceiveSubaddresses() async {
        do {
            let book = try await storage.loadSubaddressBook()
            receiveSubaddresses = book.entries
                .filter { $0.accountIndex == 0 }
                .sorted { a, b in
                    if a.subaddressIndex != b.subaddressIndex { return a.subaddressIndex < b.subaddressIndex }
                    return a.createdAt < b.createdAt
                }

            // Ensure selection is valid
            if !receiveSubaddresses.contains(where: { $0.subaddressIndex == selectedReceiveSubaddressIndex }) {
                selectedReceiveSubaddressIndex = 0
            }
        } catch {
            // Best effort; keep UI usable
            receiveSubaddresses = [ReceiveSubaddressEntry(accountIndex: 0, subaddressIndex: 0, label: "Primary", createdAt: Date())]
            selectedReceiveSubaddressIndex = 0
        }
    }

    /// Create a new receive subaddress (account 0), persist it, and select it.
    func createNewReceiveSubaddress(label: String = "") async {
        do {
            let entry = try await storage.createNewReceiveSubaddress(label: label)
            await loadReceiveSubaddresses()
            selectedReceiveSubaddressIndex = entry.subaddressIndex
        } catch {
            // Best effort; keep existing list
        }
    }

    /// Update the label for a receive subaddress and refresh list.
    func updateReceiveSubaddressLabel(subaddressIndex: UInt32, label: String) async {
        do {
            try await storage.updateReceiveSubaddressLabel(subaddressIndex: subaddressIndex, label: label)
            await loadReceiveSubaddresses()
        } catch {
            // Best effort
        }
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

    func formatXMR(_ amount: Double) -> String {
        let piconero = UInt64(max(amount, 0) * 1_000_000_000_000.0)
        return formatDisplayPiconero(piconero)
    }

    /// Best-effort snapshot for fast resume after backgrounding.
    /// Persists the core scan cache to disk so the next launch can import and continue closer to where it left off.
    func snapshotForBackground() {
        guard isWalletOpen else { return }
        Task {
            do {
                try await walletManager.snapshotState()
            } catch {
                // Best effort only
                print("⚠️ Background snapshot failed: \(error.localizedDescription)")
            }
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

            // Load receive subaddresses for this wallet session.
            await loadReceiveSubaddresses()
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

            // Persistence is authoritative: if we can't store the wallet, we should not continue,
            // otherwise the user will appear "synced" but lose the wallet on next launch.
            do {
                try await storage.storeWallet(
                    mnemonic: normalizedMnemonic,
                    metadata: metadata,
                    requireBiometrics: requireBiometrics
                )
            } catch {
                // Fallback: if biometric-protected Keychain storage fails, retry storing without biometrics.
                // This keeps the wallet usable while still storing the mnemonic in the Keychain.
                if requireBiometrics {
                    print("⚠️ Wallet persistence failed with biometrics enabled; retrying without biometrics. error=\(error.localizedDescription)")
                    do {
                        try await storage.storeWallet(
                            mnemonic: normalizedMnemonic,
                            metadata: metadata,
                            requireBiometrics: false
                        )
                        biometricsEnabled = false
                        storedMetadata?.biometricsEnabled = false
                        print("🔐 Wallet persisted successfully without biometrics fallback.")
                    } catch {
                        let message = "Wallet persistence failed (biometrics + fallback): \(error.localizedDescription)"
                        print("⚠️ \(message)")
                        errorMessage = message
                        isWalletOpen = false
                        return
                    }
                } else {
                    let message = "Wallet persistence failed: \(error.localizedDescription)"
                    print("⚠️ \(message)")
                    errorMessage = message
                    isWalletOpen = false
                    return
                }
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

        // If one is already running, don't start another.
        if refreshTask != nil { return }

        isRefreshing = true
        errorMessage = nil
        startSyncStatusPolling()

        // Run refresh in a tracked task so we can cancel it via `cancelRefresh()`.
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.stopSyncStatusPolling()
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            }

            do {
                let status = try await self.walletManager.refreshWallet()
                await MainActor.run {
                    self.applySyncStatus(status)
                }

                // Always do a final balance fetch at the end of refresh so totals are correct.
                let balance = try await self.walletManager.getBalance()
                await MainActor.run {
                    self.applyBalanceSnapshot(
                        total: balance.total,
                        unlocked: balance.unlocked,
                        allowAuthoritativeZero: self.isSynced
                    )
                }
                self.logObservedOutputsSummary(context: "refresh_done")

                // Refresh transfer history at end of refresh (authoritative)
                do {
                    // 1) Log the raw JSON we get from walletcore so we can verify whether "out" rows exist at all.
                    let json = try WalletCoreFFIClient.exportTransfersJSON(walletId: self.walletId)
                    let prefix = String(json.prefix(1200))
                    print("🧾 transfers_json wallet_id=\(self.walletId) bytes=\(json.utf8.count) prefix=\(prefix)")

                    // 2) Decode into typed rows and publish to UI.
                    let rows = try WalletCoreFFIClient.listTransfers(walletId: self.walletId)
                    await MainActor.run { self.transfers = rows }

                    // 3) Summarize directions to quickly see if we have any outgoing/spend rows.
                    var inCount = 0
                    var outCount = 0
                    var selfCount = 0
                    for r in rows {
                        switch r.direction.lowercased() {
                        case "in": inCount += 1
                        case "out": outCount += 1
                        case "self": selfCount += 1
                        default: break
                        }
                    }
                    print("🧾 transfers_summary wallet_id=\(self.walletId) rows=\(rows.count) in=\(inCount) out=\(outCount) self=\(selfCount)")
                } catch {
                    print("⚠️ transfers_refresh_failed wallet_id=\(self.walletId) error=\(error.localizedDescription)")
                }

                await self.persistMetadataUpdate()
            } catch is CancellationError {
                // User-cancelled refresh: keep UI calm; polling teardown happens in defer.
                await MainActor.run { self.errorMessage = nil }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Refresh failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func resumeOnForeground() {
        guard isWalletOpen else { return }
        if needsRefreshRetryOnNextActive {
            resumeOnDidBecomeActive()
            return
        }
        guard !isRefreshing else { return }
        guard !isSynced else { return }

        Task { [weak self] in
            await self?.refreshWallet()
        }
    }

    func markNeedsRefreshRetryIfInitialSyncInterrupted() {
        guard isWalletOpen else { return }
        guard isRefreshing else { return }
        guard lastScannedHeight <= restoreHeight else { return }

        needsRefreshRetryOnNextActive = true
        print("🧭 markNeedsRefreshRetryIfInitialSyncInterrupted set retry flag (lastScanned=\(lastScannedHeight) restoreHeight=\(restoreHeight))")
    }

    func resumeOnDidBecomeActive() {
        guard isWalletOpen else { return }
        guard !isSynced else { return }

        let shouldForceRetry = needsRefreshRetryOnNextActive || (isRefreshing && lastScannedHeight <= restoreHeight)
        if shouldForceRetry {
            needsRefreshRetryOnNextActive = false
            cancelRefresh()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 750_000_000)
                await self?.refreshWallet()
            }
            return
        } else {
            needsRefreshRetryOnNextActive = false
        }

        guard !isRefreshing else { return }

        Task { [weak self] in
            await self?.refreshWallet()
        }
    }

    /// Cancel an in-flight refresh (stops waiting/polling and returns control to UI).
    /// Note: the core may continue scanning in the background; this is a UI-level cancel.
    func cancelRefresh() {
        guard isRefreshing else { return }

        // Diagnostic: help identify *who* is triggering cancel (button tap vs lifecycle vs preemption).
        // Swift doesn't provide a cheap full backtrace here, but call-site file/line is still useful.
        let callsite = "\(#fileID):\(#line) \(#function)"
        print("🛑 VM cancelRefresh() invoked (callsite=\(callsite)) isRefreshing=\(isRefreshing) hasTask=\(refreshTask != nil)")

        refreshTask?.cancel()
        refreshTask = nil

        Task { await walletManager.cancelRefresh() }
        stopSyncStatusPolling()
        isRefreshing = false
    }

    /// Update balance without refreshing (quick check)
    func updateBalance() async {
        guard isWalletOpen else { return }

        do {
            if let status = try? await walletManager.getSyncStatus() {
                applySyncStatus(status)
            }

            let balance = try await walletManager.getBalance()
            applyBalanceSnapshot(
                total: balance.total,
                unlocked: balance.unlocked,
                allowAuthoritativeZero: isSynced
            )

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
        balanceIsStaleWhileSyncing = false
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
            applyBalanceSnapshot(
                total: balance.total,
                unlocked: balance.unlocked,
                allowAuthoritativeZero: true
            )

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
        scanRateWindowStart = nil
        scanRateWindowScanned = nil
        lastScanProgressAt = nil
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
                                let db = status.lastScanned >= prev.lastScanned ? (status.lastScanned - prev.lastScanned) : 0

                                if db > 0 {
                                    self.lastScanProgressAt = now

                                    if self.scanRateWindowStart == nil || self.scanRateWindowScanned == nil {
                                        self.scanRateWindowStart = lastUpdate
                                        self.scanRateWindowScanned = prev.lastScanned
                                    }

                                    if let windowStart = self.scanRateWindowStart,
                                       let windowScanned = self.scanRateWindowScanned {
                                        let windowDt = now.timeIntervalSince(windowStart)
                                        let windowDb = status.lastScanned >= windowScanned ? (status.lastScanned - windowScanned) : 0

                                        if windowDb > 0, windowDt >= 0.5 {
                                            self.scanBlocksPerSecond = Double(windowDb) / windowDt
                                        }
                                    }
                                } else {
                                    let staleRate = self.lastScanProgressAt.map { now.timeIntervalSince($0) > 1.5 } ?? true
                                    if staleRate {
                                        self.scanBlocksPerSecond = 0.0
                                    }
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
                                self.applyBalanceSnapshot(
                                    total: balance.total,
                                    unlocked: balance.unlocked,
                                    allowAuthoritativeZero: self.isSynced
                                )
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
                        let rows = await MainActor.run { () -> [WalletCoreFFIClient.Transfer]? in
                            // WalletManager is an actor; avoid calling actor-isolated methods from this main-actor block.
                            return try? WalletCoreFFIClient.listTransfers(walletId: self.walletId)
                        }

                        // Debug: periodically log the raw JSON and a direction summary while polling so we can
                        // catch outgoing/spend rows appearing mid-sync.
                        do {
                            let json = try WalletCoreFFIClient.exportTransfersJSON(walletId: self.walletId)
                            let prefix = String(json.prefix(600))
                            print("🧾 transfers_json(poll) wallet_id=\(self.walletId) bytes=\(json.utf8.count) prefix=\(prefix)")

                            if let rows {
                                var inCount = 0
                                var outCount = 0
                                var selfCount = 0
                                for r in rows {
                                    switch r.direction.lowercased() {
                                    case "in": inCount += 1
                                    case "out": outCount += 1
                                    case "self": selfCount += 1
                                    default: break
                                    }
                                }
                                print("🧾 transfers_summary(poll) wallet_id=\(self.walletId) rows=\(rows.count) in=\(inCount) out=\(outCount) self=\(selfCount)")
                            }
                        } catch {
                            print("⚠️ transfers_poll_debug_failed wallet_id=\(self.walletId) error=\(error.localizedDescription)")
                        }
                        if let rows {
                            await MainActor.run {
                                self.transfers = rows
                                self.lastTransfersPollAt = Date()
                            }
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
                    self.scanRateWindowStart = nil
                    self.scanRateWindowScanned = nil
                    self.lastScanProgressAt = nil
                    self.scanBlocksPerSecond = 0.0
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
        scanRateWindowStart = nil
        scanRateWindowScanned = nil
        lastScanProgressAt = nil
        scanBlocksPerSecond = 0.0
        pendingSyncPollRestart = false
    }

    private func applySyncStatus(_ status: WalletCoreFFIClient.SyncStatus) {
        let normalizedChainHeight = max(status.chainHeight, status.restoreHeight, status.lastScanned)
        let normalizedRestoreHeight = min(status.restoreHeight, normalizedChainHeight)
        let normalizedLastScanned = min(max(status.lastScanned, normalizedRestoreHeight), normalizedChainHeight)
        let tol: UInt64 = 3

        chainHeight = normalizedChainHeight
        if status.chainTime > 0 {
            chainTime = status.chainTime
        }
        restoreHeight = normalizedRestoreHeight
        lastScannedHeight = normalizedLastScanned
        if normalizedChainHeight > 0 && normalizedLastScanned + tol >= normalizedChainHeight {
            scanBlocksPerSecond = 0.0
        }
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
        balanceIsStaleWhileSyncing = false
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
            let normalizedWords = mnemonic
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            print("🧭 loadStoredWalletOnLaunch metadata walletId=\(metadata.walletId) restoreHeight=\(metadata.restoreHeight) mainnet=\(metadata.mainnet) biometricsEnabled=\(metadata.biometricsEnabled)")
            print("🧭 loadStoredWalletOnLaunch mnemonic fingerprint=\(lastOpenedMnemonicFingerprint ?? "(nil)") words=\(normalizedWords.count)")

            do {
                let address = try await walletManager.derivePrimaryAddress(
                    mnemonic: mnemonic,
                    mainnet: metadata.mainnet
                )
                walletAddress = address
                print("🧭 loadStoredWalletOnLaunch derived primary address prefix=\(String(address.prefix(12)))")
            } catch {
                print("⚠️ loadStoredWalletOnLaunch derivePrimaryAddress failed: \(error)")
                throw error
            }

            // Load receive subaddresses for this wallet session.
            await loadReceiveSubaddresses()

            // Open with the persisted restore height for this wallet.
            // If the user later replaces the seed, createWallet() will clear metadata+cache first.
            do {
            try await walletManager.openWallet(
                mnemonic: mnemonic,
                walletId: walletId,
                restoreHeight: metadata.restoreHeight,
                mainnet: metadata.mainnet
            )
                print("🧭 loadStoredWalletOnLaunch openWallet succeeded walletId=\(walletId)")
            } catch {
                print("⚠️ loadStoredWalletOnLaunch openWallet failed: \(error)")
                throw error
            }

            isWalletOpen = true

            if let balance = try? await walletManager.getBalance() {
                applyBalanceSnapshot(
                    total: balance.total,
                    unlocked: balance.unlocked,
                    allowAuthoritativeZero: isSynced
                )
            }

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
            errorMessage = error.localizedDescription
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

    private func applyBalanceSnapshot(total: UInt64, unlocked: UInt64, allowAuthoritativeZero: Bool) {
        let knownTotal = max(totalBalance, storedMetadata?.totalBalance ?? 0)
        let knownUnlocked = max(unlockedBalance, storedMetadata?.unlockedBalance ?? 0)
        let hasKnownNonZero = knownTotal > 0 || knownUnlocked > 0
        let proposedZero = total == 0 && unlocked == 0

        if proposedZero && hasKnownNonZero && !allowAuthoritativeZero {
            balanceIsStaleWhileSyncing = true
            print("🧭 Preserving known nonzero balance while sync state is not authoritative (knownTotal=\(knownTotal) proposedTotal=0)")
            return
        }

        totalBalance = total
        unlockedBalance = unlocked
        balanceIsStaleWhileSyncing = false
    }

    private func logObservedOutputsSummary(context: String) {
        do {
            let envelope = try WalletCoreFFIClient.observedOutputs(walletId: walletId)
            let spentCount = envelope.outputs.filter(\.spent).count
            let unspent = envelope.outputs.filter { !$0.spent }
            let unspentTotal = unspent.reduce(UInt64(0)) { $0 &+ $1.amount }
            let unlockedUnspentTotal = unspent.filter(\.unlocked).reduce(UInt64(0)) { $0 &+ $1.amount }
            print("🧾 outputs_summary context=\(context) wallet_id=\(walletId) rows=\(envelope.outputs.count) spent=\(spentCount) unspent=\(unspent.count) unspent_total=\(unspentTotal) unlocked_unspent_total=\(unlockedUnspentTotal)")
        } catch {
            print("⚠️ outputs_summary_failed context=\(context) wallet_id=\(walletId) error=\(error.localizedDescription)")
        }
    }
}
