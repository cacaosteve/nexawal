//
//  WalletManager.swift
//  nexawal
//
//  Manages Monero wallet operations using MoneroWalletCoreFFI
//

import Foundation
import Darwin
import MoneroWalletCoreFFI

enum WalletError: LocalizedError {
    case invalidMnemonic
    case walletOpenFailed(String)
    case refreshFailed(String)
    case balanceFailed(String)
    case statusFailed(String)
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
        case .statusFailed(let msg):
            return "Failed to determine sync status: \(msg)"
        case .addressDerivationFailed(let msg):
            return "Failed to derive address: \(msg)"
        }
    }
}

actor WalletManager {
    static let shared = WalletManager()

    private var currentWalletId: String?
    private var cachedBalance: (total: UInt64, unlocked: UInt64)?
    private var refreshInProgress: Bool = false

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
            try WalletCoreFFIClient.setGapLimit(
                walletId: walletId,
                gapLimit: MoneroConfig.gapLimit
            )
            currentWalletId = walletId
            cachedBalance = nil // Clear cached balance
        } catch {
            throw WalletError.walletOpenFailed(error.localizedDescription)
        }
    }

    /// Refresh the wallet against the Monero node
    func refreshWallet() async throws -> WalletCoreFFIClient.SyncStatus {
        guard let walletId = currentWalletId else {
            throw WalletError.refreshFailed("No wallet is currently open")
        }

        // Serialize refreshes: if one is in-flight, wait for it to finish and return latest status
        if refreshInProgress {
            while refreshInProgress {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            return try getSyncStatus()
        }
        refreshInProgress = true

        applyNetworkProxy()
        applyScanTuning()
        let nodeURL = MoneroConfig.nodeURL()
        defer { refreshInProgress = false }

        do {
            let status = try await performRefresh(walletId: walletId, nodeURL: nodeURL)
            cachedBalance = nil
            return status
        } catch let nodeError {
            do {
                if (nodeError as? CancellationError) != nil {
                    print("ℹ️ Refresh cancelled by system; returning latest status")
                    cachedBalance = nil
                    return try WalletCoreFFIClient.syncStatus(walletId: walletId)
                }
                print("⚠️ Refresh with nodeURL '\(nodeURL)' failed: \(nodeError.localizedDescription)")
                // If core reports a parallel stall/channel error, auto-fallback to sequential scan on the same node first
                if isParallelWorkerStall(nodeError.localizedDescription) {
                    await MainActor.run {
                        MoneroConfig.setScanParallelism(0)
                        MoneroConfig.setScanBatchSize(150)
                    }
                    print("↩️ Parallel stall detected; falling back to sequential scan (par=0, batch=150) and retrying on same node...")
                    let seqStatus = try await performRefresh(walletId: walletId, nodeURL: nodeURL)
                    cachedBalance = nil
                    return seqStatus
                }
                print("⚠️ Attempting refresh without nodeURL (using wallet core default)...")
                let fallbackStatus = try await performRefresh(walletId: walletId, nodeURL: nil)
                cachedBalance = nil
                print("✅ Refresh succeeded using wallet core default node")
                return fallbackStatus
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

    /// Retrieve the latest sync status values cached by the core
    func getSyncStatus() throws -> WalletCoreFFIClient.SyncStatus {
        guard let walletId = currentWalletId else {
            throw WalletError.statusFailed("No wallet is currently open")
        }

        do {
            return try WalletCoreFFIClient.syncStatus(walletId: walletId)
        } catch {
            throw WalletError.statusFailed(error.localizedDescription)
        }
    }

    private func performRefresh(walletId: String, nodeURL: String?) async throws -> WalletCoreFFIClient.SyncStatus {
        try WalletCoreFFIClient.refreshWalletAsync(walletId: walletId, nodeURL: nodeURL)
        return try await waitForRefreshCompletion(using: walletId)
    }

    private func waitForRefreshCompletion(using walletId: String, stallTimeout: TimeInterval = 45, pollInterval: TimeInterval = 0.2) async throws -> WalletCoreFFIClient.SyncStatus {
        // Stall-based wait (no fixed deadline)
        let toleranceBlocks: UInt64 = 3

        var targetHeight: UInt64?
        var lastProgressAt = Date()
        var lastScannedSnapshot: UInt64 = 0
        // Scale stall timeout based on scan tuning
        let par = MoneroConfig.scanParallelism
        let batch = MoneroConfig.scanBatchSize
        // Base on user-provided stallTimeout, but expand for larger batches and parallelism
        var dynamicStallTimeout = max(
            stallTimeout,
            min(300.0, max(45.0, (par > 0 ? Double(batch) * 0.15 : Double(batch) * 0.08)))
        )

        while true {
            let status = try WalletCoreFFIClient.syncStatus(walletId: walletId)

            // Capture the initial target chain height once (so we don't chase a moving tip).
            // Avoid locking onto restoreHeight as the target (which reads as chainHeight initially).
            if targetHeight == nil, status.chainHeight > status.restoreHeight {
                targetHeight = status.chainHeight
                print("🧭 Refresh target height set to \(targetHeight!) (restoreHeight=\(status.restoreHeight))")
            }

            // Compute the effective target (never below restore height)
            let effectiveTarget = max(targetHeight ?? status.chainHeight, status.restoreHeight)

            // Check for completion against the fixed target height
            if effectiveTarget > 0, status.lastScanned >= effectiveTarget {
                print("✅ Refresh reached target height \(effectiveTarget) (lastScanned=\(status.lastScanned))")
                return status
            }

            // Accept near-target within a small tolerance to avoid hanging on a moving tip
            if effectiveTarget > 0,
               status.lastScanned + toleranceBlocks >= effectiveTarget {
                print("⚠️ Refresh within tolerance (\(toleranceBlocks)) of target \(effectiveTarget); proceeding (lastScanned=\(status.lastScanned))")
                return status
            }

            // Track progress and detect stalls
            if status.lastScanned > lastScannedSnapshot {
                lastScannedSnapshot = status.lastScanned
                lastProgressAt = Date()
                // Periodic progress log
                print("⏳ Refresh progress: scanned=\(status.lastScanned), target=\(effectiveTarget), tip=\(status.chainHeight)")
            }

            // Timeout with detailed context
            // Early abort if core reported an error and no progress for a short window
            if Date().timeIntervalSince(lastProgressAt) > 2.0 {
                if let coreErr = WalletCoreFFIClient.lastErrorMessage(), !coreErr.isEmpty {
                    throw WalletError.refreshFailed("Core error: \(coreErr)")
                }
            }

            // Stall-based handling: extend patience dynamically instead of failing/restarting
                        if Date().timeIntervalSince(lastProgressAt) > dynamicStallTimeout {
                            print("⌛️ No progress for \(Int(dynamicStallTimeout))s; extending stall timeout and continuing (par=\(par), batch=\(batch))")
                            dynamicStallTimeout = min(dynamicStallTimeout * 1.5, 600.0) // backoff up to 10 minutes
                            lastProgressAt = Date() // reset stall clock and keep waiting
                        }

            let interval = max(pollInterval, 0.05)
            let nanoseconds = UInt64(interval * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
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

    /// Detect if an error message indicates a parallel worker stall/collector channel issue
    private func isParallelWorkerStall(_ message: String) -> Bool {
        let msg = message.lowercased()
        return msg.contains("parallel worker stalled") || msg.contains("parallel worker channel closed unexpectedly")
    }

    /// Apply HTTP proxy environment for I2P mode
    private func applyNetworkProxy() {
        if MoneroConfig.useI2P, let proxy = MoneroConfig.i2pHTTPProxyAddress, !proxy.isEmpty {
            let proxyURL = "http://\(proxy)"
            setenv("HTTP_PROXY", proxyURL, 1)
            setenv("http_proxy", proxyURL, 1)
            setenv("ALL_PROXY", proxyURL, 1)
            setenv("all_proxy", proxyURL, 1)
            unsetenv("NO_PROXY")
            unsetenv("no_proxy")
        } else {
            unsetenv("HTTP_PROXY")
            unsetenv("http_proxy")
            unsetenv("ALL_PROXY")
            unsetenv("all_proxy")
        }
    }

    /// Apply scan tuning (parallelism and batch) via environment variables
    private func applyScanTuning() {
        let par = MoneroConfig.scanParallelism
        let batch = MoneroConfig.scanBatchSize

        if par > 0 {
            setenv("WALLETCORE_SCAN_PAR", "\(par)", 1)
        } else {
            unsetenv("WALLETCORE_SCAN_PAR")
        }

        if batch > 0 {
            setenv("WALLETCORE_SCAN_BATCH", "\(batch)", 1)
        } else {
            unsetenv("WALLETCORE_SCAN_BATCH")
        }
    }
}
