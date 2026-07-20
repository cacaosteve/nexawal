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
    @Binding var selectedTab: MainTab

    // Transaction details
    @State private var selectedTransfer: WalletCoreFFIClient.Transfer?
    @State private var showTransferDetails: Bool = false

    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    private func directionLabel(_ t: WalletCoreFFIClient.Transfer) -> String {
        switch t.direction.lowercased() {
        case "in":
            return classicUI ? "RECEIVED" : "Received"
        case "out":
            return classicUI ? "SENT" : "Sent"
        case "self":
            return classicUI ? "SELF" : "Self"
        default:
            return classicUI ? t.direction.uppercased() : t.direction
        }
    }

    private func amountColor(_ t: WalletCoreFFIClient.Transfer) -> Color {
        if let p = classicPalette {
            switch t.direction.lowercased() {
            case "in":
                return p.success
            case "out":
                return p.danger
            default:
                return p.primaryText
            }
        }
        switch t.direction.lowercased() {
        case "in":
            return .green
        case "out":
            return .red
        default:
            return .primary
        }
    }

    private var panelBackground: Color {
        classicPalette?.panel ?? Color(.systemGray6)
    }

    private var pageBackground: Color {
        classicPalette?.background ?? Color(.systemBackground)
    }

    private var primaryText: Color {
        classicPalette?.primaryText ?? .primary
    }

    private var secondaryText: Color {
        classicPalette?.secondaryText ?? .secondary
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
        let text: String
        if viewModel.isSynced {
            text = "Wallet synced"
        } else if viewModel.chainHeight == 0 {
            text = "Connecting to node"
        } else if viewModel.lastScannedHeight == viewModel.restoreHeight {
            text = "Scanning blockchain"
        } else {
            text = "Syncing wallet"
        }
        return classicUI ? text.uppercased() : text
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
                    // Balance / actions
                    ZStack(alignment: .topLeading) {
                        if classicUI {
                            Image("NexawalMark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 160, height: 160)
                                .opacity(0.12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                                .padding(.trailing, 8)
                                .allowsHitTesting(false)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            Text(classicUI ? "NEXAWAL" : "Wallet")
                                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                                .foregroundColor(classicUI ? primaryText : .secondary)
                                .tracking(classicUI ? 2 : 0)

                            Text(viewModel.formatDisplayPiconero(viewModel.totalBalance))
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .foregroundColor(primaryText)

                            if viewModel.unlockedBalance != viewModel.totalBalance {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(classicUI ? "UNLOCKED" : "Unlocked")
                                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                        .foregroundColor(secondaryText)
                                    Text(viewModel.formatDisplayPiconero(viewModel.unlockedBalance))
                                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                        .foregroundColor(classicPalette?.accent ?? .blue)
                                }
                            }

                            if viewModel.balanceIsStaleWhileSyncing {
                                Label("Balance updating while sync catches up", systemImage: "clock.arrow.circlepath")
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundColor(secondaryText)
                            }

                            HStack(spacing: 12) {
                                Button(action: {
                                    selectedTab = .send
                                }) {
                                    Label(classicUI ? "SEND" : "Send", systemImage: "paperplane.fill")
                                        .font(classicUI ? .system(.body, design: .monospaced).weight(.semibold) : .body)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(classicUI ? Color.clear : Color.orange.opacity(0.9))
                                        .foregroundColor(classicUI ? (classicPalette?.accent ?? .green) : .white)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: classicUI ? 4 : 12)
                                                .stroke(classicUI ? (classicPalette?.border ?? .green) : Color.clear, lineWidth: classicUI ? 2 : 0)
                                        )
                                        .cornerRadius(classicUI ? 4 : 12)
                                }

                                Button(action: {
                                    selectedTab = .receive
                                }) {
                                    Label(classicUI ? "RECEIVE" : "Receive", systemImage: "qrcode")
                                        .font(classicUI ? .system(.body, design: .monospaced).weight(.semibold) : .body)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(classicUI ? Color.clear : Color.green.opacity(0.9))
                                        .foregroundColor(classicUI ? (classicPalette?.accent ?? .green) : .white)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: classicUI ? 4 : 12)
                                                .stroke(classicUI ? (classicPalette?.border ?? .green) : Color.clear, lineWidth: classicUI ? 2 : 0)
                                        )
                                        .cornerRadius(classicUI ? 4 : 12)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                            .stroke(classicUI ? (classicPalette?.border ?? .clear) : Color.clear, lineWidth: 1)
                    )
                    .cornerRadius(classicUI ? 4 : 16)
                    .padding(.horizontal)

                    // Status
                    VStack(alignment: .leading, spacing: 12) {
                        Text(classicUI ? "STATUS" : "Status")
                            .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                            .foregroundColor(primaryText)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(viewModel.isSynced ? (classicPalette?.success ?? .green) : (classicPalette?.accent ?? .orange))
                                    .frame(width: 10, height: 10)
                                Text(syncHeadline())
                                    .font(classicUI ? .system(.headline, design: .monospaced) : .headline)
                                    .foregroundColor(primaryText)
                            }

                            Text(syncDetail())
                                .font(classicUI ? .system(.subheadline, design: .monospaced) : .subheadline)
                                .foregroundColor(secondaryText)

                            ProgressView(value: viewModel.syncProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: classicPalette?.progress ?? .accentColor))

                            classicStatusRow(label: classicUI ? "NODE" : "Node", value: MoneroConfig.daemonAddress)
                            classicStatusRow(label: classicUI ? "SCANNED" : "Scanned", value: "\(viewModel.lastScannedHeight)")
                            classicStatusRow(label: classicUI ? "NETWORK HEIGHT" : "Network Height", value: "\(viewModel.chainHeight)")
                            classicStatusRow(label: classicUI ? "REMAINING" : "Remaining", value: "\(viewModel.remainingBlocks) blocks")
                            classicStatusRow(
                                label: classicUI ? "THROUGHPUT" : "Throughput",
                                value: String(format: "%.1f blk/s", viewModel.scanBlocksPerSecond)
                            )
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                            .stroke(classicUI ? (classicPalette?.border ?? .clear) : Color.clear, lineWidth: 1)
                    )
                    .cornerRadius(classicUI ? 4 : 16)
                    .padding(.horizontal)

                    // Recent transactions
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(classicUI ? "RECENT TRANSACTIONS" : "Recent Transactions")
                                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                                .foregroundColor(primaryText)
                            Spacer()
                            if !viewModel.transfers.isEmpty {
                                Text("\(viewModel.transfers.count)")
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundColor(secondaryText)
                            }
                        }

                        if viewModel.transfers.isEmpty {
                            Text("No transactions yet.")
                                .font(classicUI ? .system(.subheadline, design: .monospaced) : .subheadline)
                                .foregroundColor(secondaryText)
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
                                                    .font(classicUI ? .system(.subheadline, design: .monospaced).weight(.semibold) : .subheadline.weight(.semibold))
                                                    .foregroundColor(primaryText)

                                                HStack(spacing: 8) {
                                                    if let ts = formatTransferTimestamp(t) {
                                                        Text(ts)
                                                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                                            .foregroundColor(secondaryText)
                                                            .accessibilityLabel(formatTransferTimestampAbsolute(t) ?? ts)
                                                    }
                                                    Text(t.isPending ? (classicUI ? "PENDING" : "Pending") : "\(t.confirmations) conf")
                                                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                                        .foregroundColor(secondaryText)
                                                }

                                                Text(t.txid)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundColor(secondaryText)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }

                                            Spacer()

                                            VStack(alignment: .trailing, spacing: 4) {
                                                Text(viewModel.formatDisplayPiconero(t.amount))
                                                    .font(.system(.subheadline, design: .monospaced))
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(amountColor(t))

                                                if let fee = t.fee {
                                                    Text("Fee \(viewModel.formatDisplayPiconero(fee))")
                                                        .font(classicUI ? .system(.caption2, design: .monospaced) : .caption2)
                                                        .foregroundColor(secondaryText)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)

                                    if t.txid != sortedTransfers(viewModel.transfers).last?.txid {
                                        Divider()
                                            .background(classicPalette?.border.opacity(0.4) ?? Color(.separator))
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
                                                        Text(viewModel.formatExactPiconero(t.amount))
                                                        .font(
                                                            .system(.caption, design: .monospaced)
                                                        )
                                                        .foregroundColor(amountColor(t))
                                                    }
                                                    if let fee = t.fee {
                                                        HStack {
                                                            Text("Fee")
                                                            Spacer()
                                                            Text(viewModel.formatExactPiconero(fee))
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
                    .background(panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                            .stroke(classicUI ? (classicPalette?.border ?? .clear) : Color.clear, lineWidth: 1)
                    )
                    .cornerRadius(classicUI ? 4 : 16)
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
                                        .progressViewStyle(CircularProgressViewStyle(tint: classicUI ? (classicPalette?.accent ?? .accentColor) : .white))
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(viewModel.isRefreshing
                                     ? (classicUI ? "REFRESHING..." : "Refreshing...")
                                     : (classicUI ? "REFRESH WALLET" : "Refresh Wallet"))
                                    .font(classicUI ? .system(.body, design: .monospaced).weight(.semibold) : .body)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(classicUI ? Color.clear : Color.blue)
                            .foregroundColor(classicUI ? (classicPalette?.accent ?? .blue) : .white)
                            .overlay(
                                RoundedRectangle(cornerRadius: classicUI ? 4 : 12)
                                    .stroke(classicUI ? (classicPalette?.border ?? .clear) : Color.clear, lineWidth: classicUI ? 2 : 0)
                            )
                            .cornerRadius(classicUI ? 4 : 12)
                        }
                        .disabled(viewModel.isRefreshing)

                        if viewModel.isRefreshing {
                            Button(action: {
                                viewModel.cancelRefresh()
                            }) {
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                    Text(classicUI ? "CANCEL" : "Cancel")
                                        .font(classicUI ? .system(.body, design: .monospaced).weight(.semibold) : .body)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(classicUI ? Color.clear : Color.red.opacity(0.9))
                                .foregroundColor(classicUI ? (classicPalette?.danger ?? .red) : .white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: classicUI ? 4 : 12)
                                        .stroke(classicUI ? (classicPalette?.danger ?? .red) : Color.clear, lineWidth: classicUI ? 2 : 0)
                                )
                                .cornerRadius(classicUI ? 4 : 12)
                            }
                        }
                    }
                    .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        ScrollView {
                            Text(error)
                                .foregroundColor(classicPalette?.danger ?? .red)
                                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background((classicPalette?.danger ?? .red).opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("")
            .refreshable {
                await viewModel.refreshWallet()
            }
        }
    }

    @ViewBuilder
    private func classicStatusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(classicUI ? .system(.caption, design: .monospaced) : .body)
                .foregroundColor(secondaryText)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var nodeAddress: String
    @State private var networkPolicy: MoneroConfig.NetworkPolicy
    @State private var i2pRPCAddress: String
    @State private var i2pProxyAddress: String
    @State private var rescanHeightInput: String
    @State private var gapLimitInput: String
    @State private var accountGapInput: String
    @State private var requireBiometrics: Bool
    @State private var biometricsAvailable: Bool = false
    @State private var biometricsEnrolled: Bool = false
    @State private var showAdvancedRecovery: Bool = false
    @State private var saveConfirmation: String?
    @AppStorage(MoneroConfig.userDefaultsClassicUIKey) private var classicUIEnabled: Bool = false
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    init(viewModel: WalletViewModel) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._nodeAddress = State(initialValue: MoneroConfig.daemonAddress)
        self._networkPolicy = State(initialValue: MoneroConfig.networkPolicy)
        self._i2pRPCAddress = State(initialValue: MoneroConfig.i2pRPCAddress)
        self._i2pProxyAddress = State(initialValue: MoneroConfig.i2pHTTPProxyAddress ?? "")
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
                Section(header: NeonSectionHeader(title: "Appearance")) {
                    NeonToggle(title: "Classic UI", isOn: $classicUIEnabled)
                    Text("Standard non-neon look. Leave off for the neon terminal theme (default).")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                }

                Section(header: NeonSectionHeader(title: "Network & Node")) {
                    TextField("Daemon hostname:port", text: $nodeAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Example: 127.0.0.1:18092\n(Full URL will be: http://127.0.0.1:18092)")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                }

                Section(header: NeonSectionHeader(title: "Network Policy & I2P")) {
                    Picker("Policy", selection: $networkPolicy) {
                        Text("Clearnet only").tag(MoneroConfig.NetworkPolicy.clearnet)
                        Text("I2P only").tag(MoneroConfig.NetworkPolicy.i2p)
                        Text("Hybrid (scan clearnet, broadcast I2P)").tag(MoneroConfig.NetworkPolicy.hybrid)
                    }
                    .tint(classicPalette?.accent ?? .accentColor)

                    Text("Clearnet uses your daemon above. I2P/hybrid use the I2P RPC node and HTTP proxy for .b32.i2p traffic.")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

                    TextField("I2P RPC hostname:port", text: $i2pRPCAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(networkPolicy == .clearnet)
                        .opacity(networkPolicy == .clearnet ? 0.45 : 1)

                    TextField("I2P HTTP proxy host:port", text: $i2pProxyAddress)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(networkPolicy == .clearnet)
                        .opacity(networkPolicy == .clearnet ? 0.45 : 1)

                    Text("Proxy example: 127.0.0.1:4444 (I2P HTTP proxy). Required for I2P-only and hybrid broadcast.")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                }

                Section(header: NeonSectionHeader(title: "Restore & Rescan")) {
                    TextField("Restore height (optional)", text: $rescanHeightInput)
                        .keyboardType(.numberPad)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Use an earlier height if funds are missing after import, or rescan from 0 if you need a full recovery.")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                }

                Section(header: NeonSectionHeader(title: "Security")) {
                    NeonToggle(
                        title: "Require Face ID / Touch ID",
                        isOn: $requireBiometrics,
                        disabled: !biometricsAvailable || !biometricsEnrolled
                    )

                    if !biometricsAvailable {
                        Text("Biometric or device authentication is not available on this device.")
                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                    } else if !biometricsEnrolled {
                        Text("Biometric authentication is available, but no biometric data is enrolled.")
                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                    } else {
                        Text("When enabled, opening the stored wallet and sending funds will require device authentication.")
                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                            .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                    }
                }

                Section(header: NeonSectionHeader(title: "Maintenance")) {
                    Button {
                        Task {
                            do {
                                try await WalletManager.shared.clearScanCache()
                            } catch {
                                print("⚠️ Clear cache failed: \(error)")
                            }
                        }
                    } label: {
                        Text("Clear scan cache (this network)")
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundColor(classicUI ? (classicPalette?.danger ?? .red) : .red)
                }

                Section(header: NeonSectionHeader(title: "Recovery")) {
                    TextField("Restore height", text: $rescanHeightInput)
                        .keyboardType(.numberPad)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if classicUI, let palette = classicPalette {
                        Button {
                            initiateRescan()
                        } label: {
                            Text("Rescan from Height")
                                .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                        }
                        .disabled(parsedRescanHeight() == nil || isRescanInProgress)
                        .listRowBackground(Color.clear)
                        .buttonStyle(.plain)

                        Button {
                            rescanHeightInput = "0"
                            initiateRescan()
                        } label: {
                            Text("Full Rescan (from block 0)")
                                .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                        }
                        .disabled(isRescanInProgress)
                        .listRowBackground(Color.clear)
                        .buttonStyle(.plain)
                    } else {
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
                }

                Section(header: NeonSectionHeader(title: "Advanced Recovery")) {
                    NeonDisclosureGroup(
                        title: "Scan additional accounts or subaddresses",
                        isExpanded: $showAdvancedRecovery
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Only change these values if a wallet import appears incomplete after using the correct restore height.")
                                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

                            TextField("Gap limit (1-100000)", text: $gapLimitInput)
                                .keyboardType(.numberPad)
                                .foregroundStyle(classicPalette?.primaryText ?? .primary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("Controls how many receive subaddresses are scanned for this wallet.")
                                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

                            TextField("Account lookahead (1-1000)", text: $accountGapInput)
                                .keyboardType(.numberPad)
                                .foregroundStyle(classicPalette?.primaryText ?? .primary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("Controls how many Monero accounts are scanned starting at account 0.")
                                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .neonFormChrome(classicUI: classicUI, palette: classicPalette)
            .tint(classicPalette?.accent ?? .accentColor)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(classicUI ? "SETTINGS" : "Settings")
                        .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if classicUI, let palette = classicPalette {
                        Button {
                            saveSettings()
                        } label: {
                            Text("Save")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(palette.cta)
                                .foregroundStyle(palette.ctaText)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button("Save") {
                            saveSettings()
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let saveConfirmation {
                    Text(saveConfirmation)
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .padding(10)
                        .background((classicPalette?.panel ?? Color(.secondarySystemBackground)).opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .task {
                let availability = await viewModel.biometricAvailability()
                biometricsAvailable = availability.available
                biometricsEnrolled = availability.enrolled
            }
        }
    }

    private func saveSettings() {
        MoneroConfig.setDaemonAddress(nodeAddress)
        MoneroConfig.setNetworkPolicy(networkPolicy)
        MoneroConfig.setI2PRPCAddress(i2pRPCAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        let proxy = i2pProxyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        MoneroConfig.setI2PHTTPProxyAddress(proxy.isEmpty ? nil : proxy)
        MoneroConfig.setUseI2P(networkPolicy == .i2p || networkPolicy == .hybrid)
        MoneroConfig.setClassicUIEnabled(classicUIEnabled)
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
            withAnimation {
                saveConfirmation = "Saved"
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation {
                saveConfirmation = nil
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
        Task {
            await viewModel.rescan(from: height)
        }
    }
}
