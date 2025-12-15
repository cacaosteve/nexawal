import SwiftUI

struct SendView: View {
    @ObservedObject var viewModel: WalletViewModel

    @Environment(\.dismiss) private var dismiss

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

    // Outputs
    @State private var estimatedFeePiconero: UInt64?
    @State private var sentTxid: String?
    @State private var sentFeePiconero: UInt64?

    private let walletManager = WalletManager.shared

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Recipient")) {
                    TextField("Monero address", text: $toAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }

                Section(header: Text("Amount")) {
                    HStack {
                        TextField("0.0", text: $amountXMR)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Spacer()
                        Text("XMR")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Available")
                        Spacer()
                        Text(viewModel.formatXMR(viewModel.piconeroToXMR(viewModel.unlockedBalance)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Ring size")
                        Spacer()
                        TextField("16", text: $ringLenInput)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section(header: Text("Network Policy")) {
                    HStack {
                        Text("Policy")
                        Spacer()
                        Text(policyText())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Broadcast")
                        Spacer()
                        Text(MoneroConfig.broadcastNodeURL())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if (MoneroConfig.networkPolicy == .i2p || MoneroConfig.networkPolicy == .hybrid),
                       let proxy = MoneroConfig.i2pHTTPProxyAddress,
                       !proxy.isEmpty
                    {
                        HStack {
                            Text("I2P Proxy")
                            Spacer()
                            Text(proxy)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let fee = estimatedFeePiconero {
                    Section(header: Text("Fee Estimate")) {
                        HStack {
                            Text("Estimated fee")
                            Spacer()
                            Text(viewModel.formatXMR(viewModel.piconeroToXMR(fee)))
                                .font(.system(.caption, design: .monospaced))
                        }
                        if let amt = parsedAmountPiconero() {
                            HStack {
                                Text("Total (amount + fee)")
                                Spacer()
                                let total = safeAdd(amt, fee)
                                Text(viewModel.formatXMR(viewModel.piconeroToXMR(total)))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                if let txid = sentTxid, let fee = sentFeePiconero {
                    Section(header: Text("Sent")) {
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
                            Text(viewModel.formatXMR(viewModel.piconeroToXMR(fee)))
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
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section {
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
                        }
                        .disabled(isEstimating || isSending || parsedAmountPiconero() == nil || !looksLikeAddress(toAddress))

                        Button {
                            Task { await sendMax() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle")
                                Text("Send Max")
                            }
                        }
                        .disabled(isEstimating || isSending)

                        Button {
                            Task { await performSend() }
                        } label: {
                            HStack {
                                if isSending {
                                    ProgressView()
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text(isSending ? "Sending..." : "Send")
                            }
                        }
                        .disabled(isEstimating || isSending || !canSend())
                    }
                }
            }
            .navigationTitle("Send XMR")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            // Reset transient state on open
            errorMessage = nil
            infoMessage = nil
            sentTxid = nil
            sentFeePiconero = nil
            isMaxMode = false
        }
    }

    // MARK: - Actions

    private func estimateFee() async {
        guard let amountPico = parsedAmountPiconero(),
              let ring = parsedRingLen(),
              looksLikeAddress(toAddress) else {
            errorMessage = "Enter a valid address and amount."
            previewReady = false
            return
        }
        errorMessage = nil
        infoMessage = nil
        isEstimating = true
        estimatedFeePiconero = nil
        previewReady = false

        // If the user is previewing a specific amount, we are not in "Send Max" (sweep) mode.
        isMaxMode = false

        do {
            let fee = try await walletManager.previewFee(toAddress: toAddress, amountPiconero: amountPico, ringLen: ring)
            estimatedFeePiconero = fee
            previewReady = true
            infoMessage = "Fee estimated using broadcast policy."
        } catch {
            previewReady = false
            errorMessage = "Fee preview failed: \(error.localizedDescription)"
        }

        isEstimating = false
    }

    private func performSend() async {
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
            if isMaxMode {
                // In max mode, always sweep at send time so fee changes are handled correctly.
                let result = try await walletManager.sweep(toAddress: toAddress, ringLen: ring)
                sentTxid = result.txid
                sentFeePiconero = result.fee
                estimatedFeePiconero = result.fee

                // Keep UI honest: set the amount field to what was actually sent.
                let xmr = viewModel.piconeroToXMR(result.amount)
                amountXMR = String(format: "%.12f", xmr)

                infoMessage = "Swept max spendable via \(policyText())."
            } else {
                guard let amountPico = parsedAmountPiconero() else {
                    errorMessage = "Enter a valid address and amount."
                    isSending = false
                    return
                }

                // Balance sanity check for exact-amount sends
                if let fee = estimatedFeePiconero {
                    let total = safeAdd(amountPico, fee)
                    if total > viewModel.unlockedBalance {
                        errorMessage = "Insufficient unlocked balance for amount + fee."
                        isSending = false
                        return
                    }
                } else if amountPico > viewModel.unlockedBalance {
                    errorMessage = "Insufficient unlocked balance."
                    isSending = false
                    return
                }

                let result = try await walletManager.send(toAddress: toAddress, amountPiconero: amountPico, ringLen: ring)
                sentTxid = result.txid
                sentFeePiconero = result.fee
                estimatedFeePiconero = result.fee
                infoMessage = "Transaction broadcast via \(policyText())."
            }

            // Refresh balance after send
            await viewModel.updateBalance()
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

    // Real "Send Max" ("sweep"): ask the core to compute the maximum sendable amount (unlocked - fee).
    private func sendMax() async {
        errorMessage = nil
        infoMessage = nil
        estimatedFeePiconero = nil
        previewReady = false

        guard looksLikeAddress(toAddress) else {
            errorMessage = "Enter a valid address."
            return
        }

        let ring = parsedRingLen() ?? 16

        do {
            // Ask the core to compute the maximum sendable amount (unlocked - fee).
            let res = try await walletManager.previewSweep(toAddress: toAddress, ringLen: ring)
            let amount = res.amount
            let fee = res.fee

            guard amount > 0 else {
                errorMessage = "No unlocked balance available to sweep after fee."
                isMaxMode = false
                return
            }

            estimatedFeePiconero = fee
            previewReady = true
            isMaxMode = true

            let xmr = viewModel.piconeroToXMR(amount)
            amountXMR = String(format: "%.12f", xmr)
            infoMessage = "Amount set to max spendable (sweep). Final amount may change slightly at send time due to fee changes."
        } catch {
            previewReady = false
            isMaxMode = false
            errorMessage = "Fee preview failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    // Minimal mock ViewModel for preview
    let vm = WalletViewModel()
    return SendView(viewModel: vm)
}
