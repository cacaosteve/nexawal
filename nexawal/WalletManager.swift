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
    private var refreshPar: Int = 0
    private var refreshBatch: Int = 0
    private var currentNetworkMainnet: Bool = true

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
            currentNetworkMainnet = mainnet
            currentWalletId = walletId
            cachedBalance = nil // Clear cached balance
            importCacheIfPresent(for: walletId)
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
        let nodeURL = MoneroConfig.scanNodeURL()
        defer { refreshInProgress = false }

        do {
            let status = try await performRefresh(walletId: walletId, nodeURL: nodeURL)
            exportCacheAndPersist(for: walletId)
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
                    exportCacheAndPersist(for: walletId)
                    cachedBalance = nil
                    return seqStatus
                }
                print("⚠️ Attempting refresh without nodeURL (using wallet core default)...")
                let fallbackStatus = try await performRefresh(walletId: walletId, nodeURL: nil)
                exportCacheAndPersist(for: walletId)
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
        let par = refreshPar
        let batch = refreshBatch
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

            // Only compute effective target after targetHeight is known (daemon reported > restore)
            if let target = targetHeight {
                let effectiveTarget = max(target, status.restoreHeight)

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
            }

            // Track progress and detect stalls
            if status.lastScanned > lastScannedSnapshot {
                lastScannedSnapshot = status.lastScanned
                lastProgressAt = Date()
                // Periodic progress log
                print("⏳ Refresh progress: scanned=\(status.lastScanned), target=\(targetHeight ?? status.chainHeight), tip=\(status.chainHeight)")
            }

            // Timeout with detailed context
            // Early abort if core reported an error and no progress for a short window
            if Date().timeIntervalSince(lastProgressAt) > 2.0 {
                if let coreErr = WalletCoreFFIClient.lastErrorMessage(), !coreErr.isEmpty {
                    throw WalletError.refreshFailed("Core error: \(coreErr)")
                }
            }

            // Stall-based handling: on first stall, fallback to reliable sequential scan and continue
                                    if Date().timeIntervalSince(lastProgressAt) > dynamicStallTimeout {
                                        print("↩️ Stall detected (>\(Int(dynamicStallTimeout))s). Falling back to sequential scan (par=0, batch=150) and retrying…")
                                        await MoneroConfig.recordParallelStallForCurrentNode()
                                        await MoneroConfig.setScanParallelism(0)
                                        await MoneroConfig.setScanBatchSize(150)
                                        refreshPar = 0
                                        refreshBatch = 150
                                        // Restart background refresh with safer tuning
                                        try WalletCoreFFIClient.refreshWalletAsync(walletId: walletId, nodeURL: MoneroConfig.scanNodeURL())
                                        // Reset stall clock and give the sequential path time
                                        lastProgressAt = Date()
                                        dynamicStallTimeout = max(60.0, dynamicStallTimeout)
                                        continue
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

    /// Force rescan from a specific height. Resets core scan state, clears local cache, and refreshes.
    func rescan(from height: UInt64) async throws -> WalletCoreFFIClient.SyncStatus {
        guard let walletId = currentWalletId else {
            throw WalletError.refreshFailed("No wallet is currently open")
        }
        // Reset core state to the requested height
        try WalletCoreFFIClient.forceRescanFromHeight(walletId: walletId, fromHeight: height)
        // Clear persisted cache so we don't restore old state on next launch
        try clearScanCache()
        // Trigger a refresh; this will also export a fresh cache on success
        return try await refreshWallet()
    }

    /// Detect if an error message indicates a parallel worker stall/collector channel issue
    private func isParallelWorkerStall(_ message: String) -> Bool {
        let msg = message.lowercased()
        return msg.contains("parallel worker stalled") || msg.contains("parallel worker channel closed unexpectedly")
    }

    /// Import a previously exported core cache blob for this wallet, if present.
    /// - Migration note: also migrates any legacy cache stored in UserDefaults to a file.
    private func importCacheIfPresent(for walletId: String) {
        // 1) Migrate legacy cache (UserDefaults -> file)
        let legacyKey = "wallet_cache_\(walletId)"
        if let legacyBlob = UserDefaults.standard.data(forKey: legacyKey) {
            do {
                let fileURL = cacheFileURL(for: walletId)
                try ensureCacheDirectory()
                try legacyBlob.write(to: fileURL, options: .atomic)
                try excludeFromBackup(url: fileURL)
                UserDefaults.standard.removeObject(forKey: legacyKey)
                print("🗂️ Migrated legacy cache to file (\(legacyBlob.count) bytes) at \(fileURL.lastPathComponent)")
            } catch {
                print("⚠️ Legacy cache migration failed for \(walletId): \(error.localizedDescription)")
            }
        }

        // 2) Import from file if present
        let fileURL = cacheFileURL(for: walletId)
        do {
            let data = try Data(contentsOf: fileURL)
            try WalletCoreFFIClient.importCache(walletId: walletId, cacheBlob: data)
            print("🗂️ Imported wallet cache (\(data.count) bytes) for \(walletId) from file")
        } catch {
            // File may not exist on first run; ignore not found, log others
            if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSFileReadNoSuchFileError {
                print("⚠️ Cache import (file) failed for \(walletId): \(error.localizedDescription)")
            }
        }
    }

    /// Export the core cache blob and persist it to Application Support for fast resume across launches.
    private func exportCacheAndPersist(for walletId: String) {
        do {
            guard let data = try WalletCoreFFIClient.exportCache(walletId: walletId) else {
                print("🗂️ Exported wallet cache is empty for \(walletId)")
                return
            }
            try ensureCacheDirectory()
            let fileURL = cacheFileURL(for: walletId)
            try data.write(to: fileURL, options: .atomic)
            try excludeFromBackup(url: fileURL)
            print("🗂️ Exported wallet cache (\(data.count) bytes) to \(fileURL.lastPathComponent) for \(walletId)")
        } catch {
            print("⚠️ Cache export failed for \(walletId): \(error.localizedDescription)")
        }
    }

    // MARK: - Cache file utilities

    /// Directory used to store wallet cache blobs.
    private func cacheDirectoryURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Namespace for NexaWal caches with per-network subdirectory
        let netDir = currentNetworkMainnet ? "mainnet" : "stagenet"
        return appSupport
            .appendingPathComponent("WalletCaches", isDirectory: true)
            .appendingPathComponent(netDir, isDirectory: true)
    }

    /// Full path for a wallet's cache blob.
    private func cacheFileURL(for walletId: String) -> URL {
        cacheDirectoryURL().appendingPathComponent("\(walletId).cache")
    }

    /// Ensure the cache directory exists and is excluded from backups.
    private func ensureCacheDirectory() throws {
        let fm = FileManager.default
        let dir = cacheDirectoryURL()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        try excludeFromBackup(url: dir)
    }

    /// Mark a URL (file or directory) as excluded from iCloud backups.
    private func excludeFromBackup(url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    /// Apply HTTP proxy environment for I2P mode
    private func applyNetworkProxy() {
        if MoneroConfig.networkPolicy == .i2p, let proxy = MoneroConfig.i2pHTTPProxyAddress, !proxy.isEmpty {
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
        let tuning = MoneroConfig.chooseTuningForCurrentNode()
        let par = max(0, min(tuning.par, 64))
        let batch = max(50, min(tuning.batch, 5000))

        // Persist chosen tuning for this refresh so logs and stall logic are consistent
        refreshPar = par
        refreshBatch = batch

        if par > 0 {
            setenv("WALLETCORE_SCAN_PAR", "\(par)", 1)
        } else {
            unsetenv("WALLETCORE_SCAN_PAR")
        }

        setenv("WALLETCORE_SCAN_BATCH", "\(batch)", 1)
        print("🔧 Scan tuning applied: par=\(par) batch=\(batch)")
    }

    // Clear on-disk scan cache for current wallet (per network).
    // Removes per-network cache file and any legacy cache stored in UserDefaults.
    func clearScanCache() throws {
        guard let walletId = currentWalletId else {
            throw WalletError.refreshFailed("No wallet is currently open")
        }
        let fm = FileManager.default
        let fileURL = cacheFileURL(for: walletId)

        // Remove cache file if present
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
            print("🗂️ Cleared wallet cache at \(fileURL.lastPathComponent) for \(walletId)")
        } else {
            print("🗂️ No cache file to clear for \(walletId)")
        }

        // Remove any legacy cache blob in UserDefaults
        let legacyKey = "wallet_cache_\(walletId)"
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            print("🗂️ Removed legacy cache blob for \(walletId)")
        }
    }

    /// Estimate fee for a single-destination transfer using current broadcast policy.
    func previewFee(toAddress: String, amountPiconero: UInt64, ringLen: UInt8 = 16) throws -> UInt64 {
        guard let walletId = currentWalletId else {
            throw WalletError.statusFailed("No wallet is currently open")
        }
        applyBroadcastProxy()

        // Verbose logging: amount, policy, endpoint, proxy, balances
        let policy = MoneroConfig.networkPolicy
        let endpoint = MoneroConfig.broadcastNodeURL()
        let proxyDesc = MoneroConfig.i2pHTTPProxyAddress ?? "(none)"
        let amountXMR = Double(amountPiconero) / 1_000_000_000_000.0
        if let (total, unlocked) = try? getBalance() {
            let totalXMR = Double(total) / 1_000_000_000_000.0
            let unlockedXMR = Double(unlocked) / 1_000_000_000_000.0
            print("🔎 Preview start: amount=\(String(format: "%.12f", amountXMR)) XMR, ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc), balances total=\(String(format: "%.12f", totalXMR)) XMR, unlocked=\(String(format: "%.12f", unlockedXMR)) XMR")
        } else {
            print("🔎 Preview start: amount=\(String(format: "%.12f", amountXMR)) XMR, ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc)")
        }

        let dest = WalletCoreFFIClient.Destination(address: toAddress, amount: amountPiconero)
        let fee = try WalletCoreFFIClient.previewFee(
            walletId: walletId,
            destinations: [dest],
            ringLen: ringLen,
            nodeURL: endpoint
        )

        let feeXMR = Double(fee) / 1_000_000_000_000.0
        print("📦 Estimated fee: \(fee) piconero (\(String(format: "%.12f", feeXMR)) XMR)")

        return fee
    }

    /// Preview sweep ("Send Max") to a destination.
    /// - Returns: (amount, fee) in piconero where `amount` is computed by the core (roughly unlocked - fee).
    func previewSweep(toAddress: String, ringLen: UInt8 = 16) throws -> (amount: UInt64, fee: UInt64) {
        guard let walletId = currentWalletId else {
            throw WalletError.statusFailed("No wallet is currently open")
        }
        applyBroadcastProxy()

        let policy = MoneroConfig.networkPolicy
        let endpoint = MoneroConfig.broadcastNodeURL()
        let proxyDesc = MoneroConfig.i2pHTTPProxyAddress ?? "(none)"
        if let (total, unlocked) = try? getBalance() {
            let totalXMR = Double(total) / 1_000_000_000_000.0
            let unlockedXMR = Double(unlocked) / 1_000_000_000_000.0
            print("🔎 Sweep preview start: ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc), balances total=\(String(format: "%.12f", totalXMR)) XMR, unlocked=\(String(format: "%.12f", unlockedXMR)) XMR")
        } else {
            print("🔎 Sweep preview start: ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc)")
        }

        let res = try WalletCoreFFIClient.previewSweep(
            walletId: walletId,
            toAddress: toAddress,
            ringLen: ringLen,
            nodeURL: endpoint
        )

        let amountXMR = Double(res.amount) / 1_000_000_000_000.0
        let feeXMR = Double(res.fee) / 1_000_000_000_000.0
        print("📦 Sweep preview: amount=\(res.amount) piconero (\(String(format: "%.12f", amountXMR)) XMR), fee=\(res.fee) piconero (\(String(format: "%.12f", feeXMR)) XMR)")

        return res
    }

    /// Sweep ("Send Max") to a destination. Returns (txid, amount, fee).
    func sweep(toAddress: String, ringLen: UInt8 = 16) throws -> (txid: String, amount: UInt64, fee: UInt64) {
        guard let walletId = currentWalletId else {
            throw WalletError.statusFailed("No wallet is currently open")
        }
        applyBroadcastProxy()

        let policy = MoneroConfig.networkPolicy
        let endpoint = MoneroConfig.broadcastNodeURL()
        let proxyDesc = MoneroConfig.i2pHTTPProxyAddress ?? "(none)"
        if let (total, unlocked) = try? getBalance() {
            let totalXMR = Double(total) / 1_000_000_000_000.0
            let unlockedXMR = Double(unlocked) / 1_000_000_000_000.0
            print("📤 Sweep start: ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc), balances total=\(String(format: "%.12f", totalXMR)) XMR, unlocked=\(String(format: "%.12f", unlockedXMR)) XMR")
        } else {
            print("📤 Sweep start: ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc)")
        }

        let res = try WalletCoreFFIClient.sweep(
            walletId: walletId,
            toAddress: toAddress,
            ringLen: ringLen,
            nodeURL: endpoint
        )

        let amountXMR = Double(res.amount) / 1_000_000_000_000.0
        let feeXMR = Double(res.fee) / 1_000_000_000_000.0
        print("✅ Swept txid=\(res.txid), amount=\(res.amount) piconero (\(String(format: "%.12f", amountXMR)) XMR), fee=\(res.fee) piconero (\(String(format: "%.12f", feeXMR)) XMR) via \(policy) endpoint \(endpoint)")

        return res
    }

    /// Send to a single destination honoring broadcast policy (clearnet, I2P, or hybrid).
    func send(toAddress: String, amountPiconero: UInt64, ringLen: UInt8 = 16) throws -> (txid: String, fee: UInt64) {
        guard let walletId = currentWalletId else {
            throw WalletError.statusFailed("No wallet is currently open")
        }
        applyBroadcastProxy()

        // Verbose logging: amount, policy, endpoint, proxy, balances
        let policy = MoneroConfig.networkPolicy
        let endpoint = MoneroConfig.broadcastNodeURL()
        let proxyDesc = MoneroConfig.i2pHTTPProxyAddress ?? "(none)"
        let amountXMR = Double(amountPiconero) / 1_000_000_000_000.0
        if let (total, unlocked) = try? getBalance() {
            let totalXMR = Double(total) / 1_000_000_000_000.0
            let unlockedXMR = Double(unlocked) / 1_000_000_000_000.0
            print("📤 Send start: amount=\(String(format: "%.12f", amountXMR)) XMR, ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc), balances total=\(String(format: "%.12f", totalXMR)) XMR, unlocked=\(String(format: "%.12f", unlockedXMR)) XMR")
        } else {
            print("📤 Send start: amount=\(String(format: "%.12f", amountXMR)) XMR, ring=\(ringLen), policy=\(policy), broadcast=\(endpoint), proxy=\(proxyDesc)")
        }

        let result = try WalletCoreFFIClient.send(
            walletId: walletId,
            toAddress: toAddress,
            amountPiconero: amountPiconero,
            ringLen: ringLen,
            nodeURL: endpoint
        )

        let feeXMR = Double(result.fee) / 1_000_000_000_000.0
        print("✅ Sent txid=\(result.txid), fee=\(result.fee) piconero (\(String(format: "%.12f", feeXMR)) XMR) via \(policy) endpoint \(endpoint)")

        return result
    }

    /// Apply proxy settings for broadcast path (I2P only or hybrid).
    private func applyBroadcastProxy() {
        let policy = MoneroConfig.networkPolicy
        if (policy == .i2p || policy == .hybrid), let proxy = MoneroConfig.i2pHTTPProxyAddress, !proxy.isEmpty {
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
}
