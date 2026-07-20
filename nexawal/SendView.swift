import SwiftUI
import NexaWalLogic

struct SendView: View {
    @ObservedObject var viewModel: WalletViewModel

    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette
    @Environment(\.colorScheme) private var colorScheme

    // Inputs
    @State private var toAddress: String = ""
    @State private var amountXMR: String = ""
    @State private var ringLenInput: String = "16"

    // State
    @State private var isEstimating: Bool = false
    @State private var isMaxMode: Bool = false
    @State private var isSending: Bool = false
    @State private var previewReady: Bool = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var showSendConfirmation: Bool = false
    @State private var showScanner: Bool = false
    @State private var showAdvanced: Bool = false

    // Subaddress send selection (account 0 only for MVP)
    @State private var fromSubaddressMinor: UInt32 = 0
    @State private var sendFromSubaddressEnabled: Bool = false
    @State private var subaddressUnlockedOverride: UInt64?

    // Outputs
    @State private var estimatedFeePiconero: UInt64?
    @State private var sentTxid: String?
    @State private var sentFeePiconero: UInt64?

    private let walletManager = WalletManager.shared

    private func availablePiconero() -> UInt64 {
        if sendFromSubaddressEnabled, let v = subaddressUnlockedOverride {
            return v
        }
        return viewModel.unlockedBalance
    }

    private func availableLabel() -> String {
        if sendFromSubaddressEnabled {
            return "Available (selected subaddress)"
        }
        return "Available"
    }

    private func refreshSubaddressBalanceIfNeeded() async {
        guard sendFromSubaddressEnabled else {
            subaddressUnlockedOverride = nil
            return
        }
        do {
            let bal = try await walletManager.getBalance(fromSubaddressMinor: fromSubaddressMinor)
            subaddressUnlockedOverride = bal.unlocked
        } catch {
            // Best effort: if it fails, fall back to wallet-wide balance.
            subaddressUnlockedOverride = nil
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: NeonSectionHeader(title: "Recipient")) {
                    TextField("Monero address", text: $toAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                }

                Section(header: NeonSectionHeader(title: "Amount")) {
                    HStack {
                        TextField("0.0", text: $amountXMR)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        Spacer()
                        Text("XMR")
                            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                    }

                    HStack {
                        NeonFormLabel(text: availableLabel())
                        Spacer()
                        Text(viewModel.formatDisplayPiconero(availablePiconero()))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                    }

                    HStack {
                        NeonFormLabel(text: "Ring size")
                        Spacer()
                        TextField("16", text: $ringLenInput)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(classicPalette?.primaryText ?? .primary)
                    }
                }

                if let fee = estimatedFeePiconero {
                    Section(header: NeonSectionHeader(title: "Confirm")) {
                        HStack {
                            Text("Estimated fee")
                            Spacer()
                            Text(viewModel.formatExactPiconero(fee))
                                .font(.system(.caption, design: .monospaced))
                        }
                        if let amt = parsedAmountPiconero() {
                            HStack {
                                Text("Total (amount + fee)")
                                Spacer()
                                let total = safeAdd(amt, fee)
                                Text(viewModel.formatExactPiconero(total))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }

                        HStack {
                            Text("Destination")
                            Spacer()
                            Text(toAddress)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if let txid = sentTxid, let fee = sentFeePiconero {
                    Section(header: NeonSectionHeader(title: "Sent")) {
                        HStack {
                            Text("TXID")
                            Spacer()
                            Text(txid)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        HStack {
                            Text("Fee")
                            Spacer()
                            Text(viewModel.formatExactPiconero(fee))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                if let info = infoMessage {
                    Section {
                        Text(info)
                            .font(.caption)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(classicPalette?.danger ?? .red)
                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                    }
                }

                Section(header: NeonSectionHeader(title: "Actions")) {
                    if classicUI, let palette = classicPalette {
                        HStack(spacing: 12) {
                            Button {
                                Task { await estimateFee() }
                            } label: {
                                HStack {
                                    if isEstimating {
                                        ProgressView().tint(palette.accent)
                                    } else {
                                        Image(systemName: "dollarsign.circle")
                                    }
                                    Text(isEstimating ? "Estimating..." : "Preview Fee")
                                }
                                .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                            }
                            .buttonStyle(.plain)
                            .disabled(isEstimating || isSending || parsedAmountPiconero() == nil || !looksLikeAddress(toAddress))

                            Button {
                                showSendConfirmation = true
                            } label: {
                                HStack {
                                    if isSending {
                                        ProgressView().tint(palette.ctaText)
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                    }
                                    Text(isSending ? "Sending..." : "Send")
                                }
                                .neonCTAStyle(classicUI: true, palette: palette)
                            }
                            .buttonStyle(.plain)
                            .disabled(isEstimating || isSending || !canSend())
                        }
                        .listRowBackground(Color.clear)

                        Button {
                            Task { await sendMax() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle")
                                Text("Send Max")
                            }
                            .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .disabled(isEstimating || isSending)
                    } else {
                        HStack(spacing: 12) {
                            Button {
                                Task { await estimateFee() }
                            } label: {
                                HStack {
                                    if isEstimating {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "dollarsign.circle")
                                    }
                                    Text(isEstimating ? "Estimating..." : "Preview Fee")
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .disabled(isEstimating || isSending || parsedAmountPiconero() == nil || !looksLikeAddress(toAddress))

                            Button {
                                showSendConfirmation = true
                            } label: {
                                HStack {
                                    if isSending {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "paperplane.fill")
                                    }
                                    Text(isSending ? "Sending..." : "Send")
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isEstimating || isSending || !canSend())
                        }

                        Button {
                            Task { await sendMax() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle")
                                Text("Send Max")
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        .disabled(isEstimating || isSending)
                    }
                }

                Section {
                    NeonDisclosureGroup(
                        title: classicUI ? "ADVANCED" : "Advanced",
                        isExpanded: $showAdvanced
                    ) {
                        NeonToggle(title: "Send from specific subaddress", isOn: $sendFromSubaddressEnabled)

                        if sendFromSubaddressEnabled {
                            Picker("Subaddress", selection: $fromSubaddressMinor) {
                                ForEach(viewModel.receiveSubaddresses, id: \.subaddressIndex) { e in
                                    let label = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let title = label.isEmpty ? "Subaddress \(e.subaddressIndex)" : label
                                    Text(title).tag(e.subaddressIndex)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(classicPalette?.accent ?? .accentColor)

                            Text("This constrains inputs to account 0, subaddress \(fromSubaddressMinor).")
                                .font(.caption)
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                        }

                        HStack {
                            NeonFormLabel(text: "Policy")
                            Spacer()
                            Text(policyText())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                        }

                        HStack {
                            NeonFormLabel(text: "Broadcast")
                            Spacer()
                            Text(MoneroConfig.broadcastNodeURL())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                        }

                        if (MoneroConfig.networkPolicy == .i2p || MoneroConfig.networkPolicy == .hybrid),
                           let proxy = MoneroConfig.i2pHTTPProxyAddress,
                           !proxy.isEmpty
                        {
                            HStack {
                                NeonFormLabel(text: "I2P Proxy")
                                Spacer()
                                Text(proxy)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(classicUI ? "SEND" : "Send XMR")
                        .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .foregroundStyle(classicPalette?.accent ?? .accentColor)
                }
            }
            .neonFormChrome(classicUI: classicUI, palette: classicPalette)
            .tint(classicPalette?.accent ?? .accentColor)
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    handleScannedCode(code)
                }
                .classicTheme(enabled: classicUI, colorScheme: colorScheme)
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            // Reset transient state on open
            errorMessage = nil
            infoMessage = nil
            sentTxid = nil
            sentFeePiconero = nil
            isMaxMode = false

            // Ensure subaddress list is loaded for picker
            Task {
                await viewModel.loadReceiveSubaddresses()
                await refreshSubaddressBalanceIfNeeded()
            }
        }
        .onChange(of: sendFromSubaddressEnabled) {
            Task { await refreshSubaddressBalanceIfNeeded() }
        }
        .onChange(of: fromSubaddressMinor) {
            Task { await refreshSubaddressBalanceIfNeeded() }
        }
        .confirmationDialog(
            "Confirm Send",
            isPresented: $showSendConfirmation,
            titleVisibility: .visible
        ) {
            Button("Confirm Send") {
                Task {
                    await performSend()
                }
            }
            Button("Cancel", role: .cancel) {
            }
        } message: {
            Text(confirmationMessage())
        }
    }

    // MARK: - In-flight task cancellation / debouncing
    //
    // These are critical to avoid runaway repeated RPC calls when the user taps actions repeatedly
    // or when SwiftUI triggers state updates while an async operation is still running.
    @State private var feePreviewTask: Task<Void, Never>?
    @State private var sweepPreviewTask: Task<Void, Never>?

    // MARK: - Actions

    private func estimateFee() async {
        let walletId = await walletManager.getCurrentWalletId() ?? "(none)"
        print("🧭 UI action: estimateFee tapped wallet_id=\(walletId) isMaxMode=\(isMaxMode) sendFromSubaddressEnabled=\(sendFromSubaddressEnabled) fromSubaddressMinor=\(fromSubaddressMinor) amountXMR=\(amountXMR) toAddress_prefix=\(String(toAddress.prefix(12)))")

        // Cancel any previous fee preview and start a new one.
        feePreviewTask?.cancel()

        feePreviewTask = Task {
            // Small debounce to coalesce rapid taps / state changes.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }

            guard let amountPico = parsedAmountPiconero(),
                  let ring = parsedRingLen(),
                  looksLikeAddress(toAddress) else {
                await MainActor.run {
                    errorMessage = "Enter a valid address and amount."
                    previewReady = false
                }
                return
            }

            await MainActor.run {
                errorMessage = nil
                infoMessage = nil
                isEstimating = true
                estimatedFeePiconero = nil
                previewReady = false
                // If the user is previewing a specific amount, we are not in "Send Max" (sweep) mode.
                isMaxMode = false
            }

            do {
                let fee: UInt64
                if sendFromSubaddressEnabled {
                    fee = try await walletManager.previewFee(
                        fromSubaddressMinor: fromSubaddressMinor,
                        toAddress: toAddress,
                        amountPiconero: amountPico,
                        ringLen: ring
                    )
                    if Task.isCancelled { return }
                    await MainActor.run {
                        infoMessage = "Fee estimated (inputs constrained to selected subaddress)."
                    }
                } else {
                    fee = try await walletManager.previewFee(toAddress: toAddress, amountPiconero: amountPico, ringLen: ring)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        infoMessage = "Fee estimated using broadcast policy."
                    }
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    estimatedFeePiconero = fee
                    previewReady = true
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    previewReady = false
                    errorMessage = "Fee preview failed: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                isEstimating = false
            }
        }

        // Keep API signature; caller awaits immediately, but work happens in the managed task.
        await feePreviewTask?.value
    }

    private func performSend() async {
        let walletId = await walletManager.getCurrentWalletId() ?? "(none)"
        print("🧭 UI action: performSend tapped wallet_id=\(walletId) isMaxMode=\(isMaxMode) sendFromSubaddressEnabled=\(sendFromSubaddressEnabled) fromSubaddressMinor=\(fromSubaddressMinor) amountXMR=\(amountXMR) previewReady=\(previewReady) feePiconero=\(estimatedFeePiconero.map(String.init) ?? "(nil)") toAddress_prefix=\(String(toAddress.prefix(12)))")

        guard let ring = parsedRingLen(),
              looksLikeAddress(toAddress) else {
            errorMessage = "Enter a valid address and amount."
            return
        }
        guard previewReady, estimatedFeePiconero != nil else {
            errorMessage = "Preview the fee before sending."
            return
        }

        errorMessage = nil
        infoMessage = nil
        isSending = true
        sentTxid = nil
        sentFeePiconero = nil

        do {
            try await viewModel.authenticateForSensitiveAction(prompt: "Authenticate to send Monero")
            if isMaxMode {
                // In max mode, always sweep at send time so fee changes are handled correctly.
                let result: (txid: String, amount: UInt64, fee: UInt64)
                if sendFromSubaddressEnabled {
                    result = try await walletManager.sweep(fromSubaddressMinor: fromSubaddressMinor, toAddress: toAddress, ringLen: ring)
                    infoMessage = "Swept max spendable from selected subaddress via \(policyText())."
                } else {
                    result = try await walletManager.sweep(toAddress: toAddress, ringLen: ring)
                    infoMessage = "Swept max spendable via \(policyText())."
                }

                sentTxid = result.txid
                sentFeePiconero = result.fee
                estimatedFeePiconero = result.fee

                // Keep UI honest: set the amount field to what was actually sent.
                let xmr = viewModel.piconeroToXMR(result.amount)
                amountXMR = String(format: "%.12f", xmr)
            } else {
                guard let amountPico = parsedAmountPiconero() else {
                    errorMessage = "Enter a valid address and amount."
                    isSending = false
                    return
                }

                // Balance sanity check for exact-amount sends.
                // If sending from a subaddress, validate against that subaddress's unlocked balance.
                let available = availablePiconero()
                if let fee = estimatedFeePiconero {
                    if !SendSafety.hasUnlockedForExactSend(
                        amountPiconero: amountPico,
                        feePiconero: fee,
                        unlockedPiconero: available
                    ) {
                        errorMessage = "Insufficient unlocked balance for amount + fee."
                        isSending = false
                        return
                    }
                } else if amountPico > available {
                    errorMessage = "Insufficient unlocked balance."
                    isSending = false
                    return
                }

                let result: (txid: String, fee: UInt64)
                if sendFromSubaddressEnabled {
                    result = try await walletManager.send(
                        fromSubaddressMinor: fromSubaddressMinor,
                        toAddress: toAddress,
                        amountPiconero: amountPico,
                        ringLen: ring
                    )
                    infoMessage = "Transaction broadcast from selected subaddress via \(policyText())."
                } else {
                    result = try await walletManager.send(toAddress: toAddress, amountPiconero: amountPico, ringLen: ring)
                    infoMessage = "Transaction broadcast via \(policyText())."
                }

                sentTxid = result.txid
                sentFeePiconero = result.fee
                estimatedFeePiconero = result.fee
            }

            // Refresh balance after send
            await viewModel.updateBalance()
            await refreshSubaddressBalanceIfNeeded()
        } catch {
            errorMessage = "Send failed: \(error.localizedDescription)"
        }

        isSending = false
    }

    // MARK: - Helpers

    private func parsedRingLen() -> UInt8? {
        let trimmed = ringLenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = UInt8(trimmed), v >= 3 && v <= 128 else { return nil }
        return v
    }

    private func parsedAmountPiconero() -> UInt64? {
        let raw = amountXMR.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // Support comma decimal by normalizing to dot
        let norm = raw.replacingOccurrences(of: ",", with: ".")
        // Parse up to 12 decimals
        let parts = norm.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let intPartStr = parts.first else { return nil }
        let fracPartStr = parts.count > 1 ? String(parts[1]) : ""
        guard let intPart = UInt64(intPartStr) else { return nil }

        let scale = 12
        let frac = fracPartStr.prefix(scale)
        let padCount = scale - frac.count
        let fracPadded = frac + String(repeating: "0", count: padCount)
        guard let fracPart = UInt64(fracPadded) else { return nil }

        let base: UInt64 = 1_000_000_000_000
        let total = safeMul(intPart, base)
        return safeAdd(total, fracPart)
    }

    private func canSend() -> Bool {
        guard !isSending, !isEstimating else { return false }
        guard parsedAmountPiconero() != nil, parsedRingLen() != nil else { return false }
        guard looksLikeAddress(toAddress) else { return false }
        guard previewReady, estimatedFeePiconero != nil else { return false }
        return true
    }

    private func looksLikeAddress(_ addr: String) -> Bool {
        // Basic heuristic: Monero addresses commonly start with '4' or '8' (stagenet/testnet), or '5' for integrated; I2P address not expected here.
        // Keep it lenient in UI; the core will strictly validate on send.
        let s = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        let first = s.first
        if first == "4" || first == "8" || first == "5" { return true }
        // If not typical but non-empty, let core validate
        return true
    }

    private func policyText() -> String {
        switch MoneroConfig.networkPolicy {
        case .clearnet: return "Clearnet only"
        case .i2p: return "I2P only"
        case .hybrid: return "Scan clearnet, broadcast I2P"
        }
    }

    private func safeAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }

    private func safeMul(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (prod, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? UInt64.max : prod
    }
    
    private func handleScannedCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased().hasPrefix("monero:") {
            parseMoneroUri(trimmed)
        } else if looksLikeAddress(trimmed) {
            toAddress = trimmed
            infoMessage = "Address loaded from QR code."
        } else {
            errorMessage = "Invalid QR code. Expected Monero address or payment URI."
        }

        estimatedFeePiconero = nil
        previewReady = false
    }

    /// Parse `monero:<address>?…` and `monero://<address>?…` without lowercasing Base58.
    private func parseMoneroUri(_ uri: String) {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("monero:") else {
            errorMessage = "Invalid payment URI format."
            return
        }

        var remainder = String(trimmed.dropFirst("monero:".count))
        if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst(2))
        }

        let addressCandidate: String
        let queryString: String?
        if let q = remainder.firstIndex(of: "?") {
            addressCandidate = String(remainder[..<q])
            queryString = String(remainder[remainder.index(after: q)...])
        } else {
            addressCandidate = remainder
            queryString = nil
        }

        // Strip any accidental path slashes; keep Base58 case intact.
        let address = addressCandidate
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard looksLikeAddress(address) else {
            errorMessage = "No valid address in payment URI."
            return
        }

        toAddress = address

        if let queryString, !queryString.isEmpty {
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawName = parts.first.map(String.init) else { continue }
                let name = rawName.lowercased()
                let value = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""

                if name == "amount" || name == "tx_amount", !value.isEmpty {
                    if let xmr = Double(value) {
                        amountXMR = String(format: "%.12f", xmr)
                    }
                }
            }
        }

        infoMessage = "Payment details loaded from QR code."
    }

    private func confirmationMessage() -> String {
        let destination = toAddress.isEmpty ? "Unknown address" : toAddress
        if let fee = estimatedFeePiconero, let amount = parsedAmountPiconero() {
            let total = safeAdd(amount, fee)
            return "Send \(viewModel.formatExactPiconero(amount)) to \(destination).\nFee: \(viewModel.formatExactPiconero(fee))\nTotal: \(viewModel.formatExactPiconero(total))"
        }
        return "Preview the fee before sending to \(destination)."
    }

    // One-shot "Send Max": ask the core to compute the maximum sendable amount (unlocked - fee),
    // then fill the amount field so the confirmation dialog can use a previewed amount.
    private func sendMax() async {
        let walletId = await walletManager.getCurrentWalletId() ?? "(none)"
        print("🧭 UI action: sendMax tapped wallet_id=\(walletId) isMaxMode=\(isMaxMode) sendFromSubaddressEnabled=\(sendFromSubaddressEnabled) fromSubaddressMinor=\(fromSubaddressMinor) amountXMR_before=\(amountXMR) toAddress_prefix=\(String(toAddress.prefix(12)))")

        // Cancel any previous sweep preview and start a new one.
        sweepPreviewTask?.cancel()

        sweepPreviewTask = Task {
            // Small debounce to coalesce rapid taps / state changes.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }

            await MainActor.run {
                errorMessage = nil
                infoMessage = nil
                estimatedFeePiconero = nil
                previewReady = false
            }

            guard looksLikeAddress(toAddress) else {
                await MainActor.run {
                    errorMessage = "Enter a valid address."
                }
                return
            }

            let ring = parsedRingLen() ?? 16

            do {
                let res: (amount: UInt64, fee: UInt64)
                if sendFromSubaddressEnabled {
                    res = try await walletManager.previewSweep(fromSubaddressMinor: fromSubaddressMinor, toAddress: toAddress, ringLen: ring)
                } else {
                    res = try await walletManager.previewSweep(toAddress: toAddress, ringLen: ring)
                }

                if Task.isCancelled { return }

                let amount = res.amount
                let fee = res.fee

                guard amount > 0 else {
                    await MainActor.run {
                        errorMessage = "No unlocked balance available to send after fee."
                        isMaxMode = false
                        previewReady = false
                    }
                    return
                }

                await MainActor.run {
                    estimatedFeePiconero = fee
                    previewReady = true
                    // One-shot behavior: do NOT set isMaxMode=true here.
                    isMaxMode = false

                    let xmr = viewModel.piconeroToXMR(amount)
                    amountXMR = String(format: "%.12f", xmr)
                    infoMessage = "Amount set to max spendable. Final fee may change slightly at send time."
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    previewReady = false
                    isMaxMode = false
                    errorMessage = "Fee preview failed: \(error.localizedDescription)"
                }
            }
        }

        await sweepPreviewTask?.value
    }
}

// MARK: - Preview

#Preview {
    // Minimal mock ViewModel for preview
    let vm = WalletViewModel()
    return SendView(viewModel: vm)
}
