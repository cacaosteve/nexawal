//
//  WalletView.swift
//  nexawal
//
//  Main wallet view showing balance and address
//

import MoneroWalletCoreFFI
import SwiftUI
import UIKit

struct WalletView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var showSettings: Bool = false
    @State private var showReceive: Bool = false
    @State private var showSend: Bool = false

    // Transaction details
    @State private var selectedTransfer: WalletCoreFFIClient.Transfer?
    @State private var showTransferDetails: Bool = false

    private func directionLabel(_ t: WalletCoreFFIClient.Transfer) -> String {
        switch t.direction.lowercased() {
        case "in":
            return "Received"
        case "out":
            return "Sent"
        case "self":
            return "Self"
        default:
            return t.direction
        }
    }

    private func amountColor(_ t: WalletCoreFFIClient.Transfer) -> Color {
        switch t.direction.lowercased() {
        case "in":
            return .green
        case "out":
            return .red
        default:
            return .primary
        }
    }

    private func formatTransferTimestamp(_ t: WalletCoreFFIClient.Transfer) -> String? {
        guard let ts = t.timestamp, ts > 0 else { return nil }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let seconds = Int(Date().timeIntervalSince(d))

        // Future timestamps shouldn't happen, but if they do, fall back to absolute formatting.
        if seconds < 0 {
            return formatTransferTimestampAbsolute(t)
        }

        // Very small deltas
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        return formatTransferTimestampAbsolute(t)
    }

    private func formatTransferTimestampAbsolute(_ t: WalletCoreFFIClient.Transfer) -> String? {
        guard let ts = t.timestamp, ts > 0 else { return nil }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func sortedTransfers(_ items: [WalletCoreFFIClient.Transfer]) -> [WalletCoreFFIClient
        .Transfer]
    {
        items.sorted { a, b in
            // Pending first
            if a.isPending != b.isPending { return a.isPending && !b.isPending }

            // Then by height desc (unknown height treated as 0)
            let ah = a.height ?? 0
            let bh = b.height ?? 0
            if ah != bh { return ah > bh }

            // Then by timestamp desc (unknown treated as 0)
            let at = a.timestamp ?? 0
            let bt = b.timestamp ?? 0
            if at != bt { return at > bt }

            // Finally stable tiebreaker
            return a.txid > b.txid
        }
    }

    private func syncHeadline() -> String {
        if viewModel.isSynced { return "Wallet synced" }
        if viewModel.chainHeight == 0 { return "Connecting to node" }
        if viewModel.lastScannedHeight == viewModel.restoreHeight { return "Scanning blockchain" }
        return "Syncing wallet"
    }

    private func syncDetail() -> String {
        if viewModel.isSynced {
            return "Scanned to block \(viewModel.lastScannedHeight)"
        }
        if viewModel.chainHeight == 0 {
            return "Waiting for network height"
        }
        if viewModel.lastScannedHeight == viewModel.restoreHeight {
            return "Fetching initial blocks from \(viewModel.restoreHeight)"
        }
        return "\(viewModel.remainingBlocks) blocks remaining"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Wallet")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text(viewModel.formatXMR(viewModel.piconeroToXMR(viewModel.totalBalance)))
                            .font(.system(size: 38, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)

                        if viewModel.unlockedBalance != viewModel.totalBalance {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Unlocked")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(
                                    viewModel.formatXMR(
                                        viewModel.piconeroToXMR(viewModel.unlockedBalance))
                                )
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundColor(.blue)
                            }
                        }

                        if viewModel.balanceIsStaleWhileSyncing {
                            Label("Balance updating while sync catches up", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button(action: {
                                showSend = true
                            }) {
                                Label("Send", systemImage: "paperplane.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.orange.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }

                            Button(action: {
                                showReceive = true
                            }) {
                                Label("Receive", systemImage: "qrcode")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.green.opacity(0.9))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Status")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isSynced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                    .foregroundColor(viewModel.isSynced ? .green : .orange)
                                Text(syncHeadline())
                                    .font(.headline)
                            }

                            Text(syncDetail())
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            ProgressView(value: viewModel.syncProgress)
                                .progressViewStyle(LinearProgressViewStyle())

                            HStack {
                                Text("Node")
                                Spacer()
                                Text(MoneroConfig.daemonAddress)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            HStack {
                                Text("Scanned")
                                Spacer()
                                Text("\(viewModel.lastScannedHeight)")
                                    .font(.system(.caption, design: .monospaced))
                            }

                            HStack {
                                Text("Network Height")
                                Spacer()
                                Text("\(viewModel.chainHeight)")
                                    .font(.system(.caption, design: .monospaced))
                            }

                            if !viewModel.isSynced {
                                HStack {
                                    Text("Remaining")
                                    Spacer()
                                    Text("\(viewModel.remainingBlocks) blocks")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }

                            if viewModel.scanBlocksPerSecond > 0 {
                                HStack {
                                    Text("Throughput")
                                    Spacer()
                                    Text(String(format: "%.1f blk/s", viewModel.scanBlocksPerSecond))
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent Transactions")
                                .font(.headline)
                            Spacer()
                            if !viewModel.transfers.isEmpty {
                                Text("\(viewModel.transfers.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if viewModel.transfers.isEmpty {
                            Text("No transactions yet.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(sortedTransfers(viewModel.transfers), id: \.txid) { t in
                                    Button {
                                        selectedTransfer = t
                                        showTransferDetails = true
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: t.direction.lowercased() == "in" ? "arrow.down.left.circle.fill" : "arrow.up.right.circle.fill")
                                                .font(.title3)
                                                .foregroundColor(amountColor(t))

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(directionLabel(t))
                                                    .font(.subheadline)
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(.primary)

                                                HStack(spacing: 8) {
                                                    if let ts = formatTransferTimestamp(t) {
                                                        Text(ts)
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                            .accessibilityLabel(formatTransferTimestampAbsolute(t) ?? ts)
                                                    }
                                                    Text(t.isPending ? "Pending" : "\(t.confirmations) conf")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }

                                                Text(t.txid)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer()

                                            VStack(alignment: .trailing, spacing: 4) {
                                                let amtXMR = viewModel.piconeroToXMR(t.amount)
                                                Text(viewModel.formatXMR(amtXMR))
                                                    .font(.system(.subheadline, design: .monospaced))
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(amountColor(t))

                                                if let fee = t.fee {
                                                    let feeXMR = viewModel.piconeroToXMR(fee)
                                                    Text("Fee \(viewModel.formatXMR(feeXMR))")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)

                                    if t.txid != sortedTransfers(viewModel.transfers).last?.txid {
                                        Divider()
                                    }
                                }
                            }
                            .sheet(
                                isPresented: $showTransferDetails,
                                onDismiss: { selectedTransfer = nil }
                            ) {
                                if let t = selectedTransfer {
                                    NavigationView {
                                        List {
                                                Section(header: Text("Summary")) {
                                                    HStack {
                                                        Text("Type")
                                                        Spacer()
                                                        Text(directionLabel(t))
                                                            .font(
                                                                .system(
                                                                    .caption, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                    }
                                                    HStack {
                                                        Text("Status")
                                                        Spacer()
                                                        Text(t.isPending ? "Pending" : "Confirmed")
                                                            .font(
                                                                .system(
                                                                    .caption, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                    }
                                                    HStack {
                                                        Text("Amount")
                                                        Spacer()
                                                        Text(
                                                            viewModel.formatXMR(
                                                                viewModel.piconeroToXMR(t.amount))
                                                        )
                                                        .font(
                                                            .system(.caption, design: .monospaced)
                                                        )
                                                        .foregroundColor(amountColor(t))
                                                    }
                                                    if let fee = t.fee {
                                                        HStack {
                                                            Text("Fee")
                                                            Spacer()
                                                            Text(
                                                                viewModel.formatXMR(
                                                                    viewModel.piconeroToXMR(fee))
                                                            )
                                                            .font(
                                                                .system(
                                                                    .caption, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                        }
                                                    }
                                                }

                                                Section(header: Text("Chain")) {
                                                    HStack {
                                                        Text("Height")
                                                        Spacer()
                                                        Text(t.height.map(String.init) ?? "—")
                                                            .font(
                                                                .system(
                                                                    .caption, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                    }
                                                    HStack {
                                                        Text("Confirmations")
                                                        Spacer()
                                                        Text("\(t.confirmations)")
                                                            .font(
                                                                .system(
                                                                    .caption, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                    }
                                                    HStack {
                                                        Text("Time")
                                                        Spacer()
                                                        Text(
                                                            formatTransferTimestampAbsolute(t)
                                                                ?? "—"
                                                        )
                                                        .font(
                                                            .system(.caption, design: .monospaced)
                                                        )
                                                        .foregroundColor(.secondary)
                                                    }
                                                }

                                                Section(header: Text("Identifiers")) {
                                                    HStack {
                                                        Text("TXID")
                                                        Spacer()
                                                        Text(t.txid)
                                                            .font(
                                                                .system(
                                                                    .caption2, design: .monospaced)
                                                            )
                                                            .foregroundColor(.secondary)
                                                            .textSelection(.enabled)
                                                    }

                                                    Button {
                                                        UIPasteboard.general.string = t.txid
                                                    } label: {
                                                        HStack {
                                                            Text("Copy TXID")
                                                            Spacer()
                                                            Image(systemName: "doc.on.doc")
                                                                .foregroundColor(.secondary)
                                                        }
                                                    }
                                                }
                                            }
                                            .navigationTitle("Transaction")
                                            .toolbar {
                                                ToolbarItem(placement: .cancellationAction) {
                                                    Button("Close") { showTransferDetails = false }
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button(action: {
                            Task {
                                await viewModel.refreshWallet()
                            }
                        }) {
                            HStack {
                                if viewModel.isRefreshing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(viewModel.isRefreshing ? "Refreshing..." : "Refresh Wallet")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(viewModel.isRefreshing)

                        if viewModel.isRefreshing {
                            Button(action: {
                                viewModel.cancelRefresh()
                            }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Cancel")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.9))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        ScrollView {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showReceive) {
                ReceiveView(viewModel: viewModel)
            }
            .sheet(isPresented: $showSend) {
                SendView(viewModel: viewModel)
            }
            .refreshable {
                await viewModel.refreshWallet()
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var nodeAddress: String
    @State private var rescanHeightInput: String
    @State private var gapLimitInput: String
    @State private var accountGapInput: String
    @State private var requireBiometrics: Bool
    @State private var biometricsAvailable: Bool = false
    @State private var biometricsEnrolled: Bool = false
    @State private var showAdvancedRecovery: Bool = false
    @Environment(\.dismiss) var dismiss

    init(viewModel: WalletViewModel) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._nodeAddress = State(initialValue: MoneroConfig.daemonAddress)
        let heightValue = viewModel.restoreHeight
        self._rescanHeightInput = State(initialValue: heightValue == 0 ? "" : String(heightValue))
        self._gapLimitInput = State(initialValue: String(MoneroConfig.gapLimit))
        self._accountGapInput = State(initialValue: String(MoneroConfig.accountGap))
        self._requireBiometrics = State(initialValue: viewModel.biometricsEnabled)
    }

    private var isRescanInProgress: Bool {
        viewModel.isRefreshing
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Network & Node")) {
                    TextField("Daemon hostname:port", text: $nodeAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Example: 192.168.4.137:18081\n(Full URL will be: http://192.168.4.137:18081)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Restore & Rescan")) {
                    TextField("Restore height (optional)", text: $rescanHeightInput)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Use an earlier height if funds are missing after import, or rescan from 0 if you need a full recovery.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Security")) {
                    Toggle("Require Face ID / Touch ID", isOn: $requireBiometrics)
                        .disabled(!biometricsAvailable || !biometricsEnrolled)

                    if !biometricsAvailable {
                        Text("Biometric or device authentication is not available on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if !biometricsEnrolled {
                        Text("Biometric authentication is available, but no biometric data is enrolled.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("When enabled, opening the stored wallet and sending funds will require device authentication.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Maintenance")) {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await WalletManager.shared.clearScanCache()
                            } catch {
                                print("⚠️ Clear cache failed: \(error)")
                            }
                        }
                    } label: {
                        Text("Clear scan cache (this network)")
                    }
                }

                Section(header: Text("Rescan Wallet")) {
                    TextField("Restore height", text: $rescanHeightInput)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Rescan from Height") {
                        initiateRescan()
                    }
                    .disabled(parsedRescanHeight() == nil || isRescanInProgress)

                    Button("Full Rescan (from block 0)") {
                        rescanHeightInput = "0"
                        initiateRescan()
                    }
                    .disabled(isRescanInProgress)
                }

                Section(header: Text("Advanced Recovery")) {
                    DisclosureGroup("Scan additional accounts or subaddresses", isExpanded: $showAdvancedRecovery) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Only change these values if a wallet import appears incomplete after using the correct restore height.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Gap limit (1-100000)", text: $gapLimitInput)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("Controls how many receive subaddresses are scanned for this wallet.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Account lookahead (1-1000)", text: $accountGapInput)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("Controls how many Monero accounts are scanned starting at account 0.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        MoneroConfig.setDaemonAddress(nodeAddress)
                        if let gap = parsedGapLimit() {
                            MoneroConfig.setGapLimit(gap)
                            Task {
                                if let id = await WalletManager.shared.getCurrentWalletId() {
                                    try? WalletCoreFFIClient.setGapLimit(
                                        walletId: id, gapLimit: gap)
                                }
                            }
                        }
                        if let acc = Int(accountGapInput) {
                            let clamped = max(1, min(acc, 1000))
                            MoneroConfig.setAccountGap(clamped)
                        }

                        Task {
                            await viewModel.updateBiometricProtection(enabled: requireBiometrics)
                            dismiss()
                        }
                    }
                }
            }
            .task {
                let availability = await viewModel.biometricAvailability()
                biometricsAvailable = availability.available
                biometricsEnrolled = availability.enrolled
            }
        }
    }

    private func parsedGapLimit() -> UInt32? {
        let trimmed = gapLimitInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let v = UInt32(trimmed) else { return nil }
        let clamped = min(max(v, 1), 100_000)
        return clamped
    }

    private func parsedRescanHeight() -> UInt64? {
        let trimmed = rescanHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = UInt64(trimmed) else {
            return nil
        }
        return value
    }

    private func initiateRescan() {
        guard let height = parsedRescanHeight() else { return }
        dismiss()
        Task {
            await viewModel.rescan(from: height)
        }
    }
}
