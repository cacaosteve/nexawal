//
//  WalletView.swift
//  nexawal
//
//  Main wallet view showing balance and address
//

import SwiftUI
import MoneroWalletCoreFFI

struct WalletView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var showSettings: Bool = false
    @State private var showReceive: Bool = false
    @State private var showSend: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance Card
                    VStack(spacing: 16) {
                        Text("Total Balance")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text(viewModel.formatXMR(viewModel.piconeroToXMR(viewModel.totalBalance)))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)

                        Divider()

                        Text("Unlocked Balance")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(viewModel.formatXMR(viewModel.piconeroToXMR(viewModel.unlockedBalance)))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // Address Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wallet Address")
                            .font(.headline)

                        Text(viewModel.walletAddress)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal)

                    // Status Info
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sync Status")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Chain Height")
                                Spacer()
                                Text("\(viewModel.chainHeight)")
                                    .font(.system(.body, design: .monospaced))
                            }

                            HStack {
                                Text("Last Scanned")
                                Spacer()
                                Text("\(viewModel.lastScannedHeight)")
                                    .font(.system(.body, design: .monospaced))
                            }

                            if !viewModel.isSynced {
                                HStack {
                                    Text("Remaining Blocks")
                                    Spacer()
                                    Text("\(viewModel.remainingBlocks)")
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: viewModel.syncProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                            Text(
                                viewModel.isSynced
                                ? "Wallet is fully synced"
                                : (
                                    viewModel.remainingBlocks <= 5
                                    ? "Finalizing…"
                                    : (
                                        (viewModel.chainHeight == 0 || viewModel.lastScannedHeight == viewModel.restoreHeight)
                                        ? "Initializing scan…"
                                        : "Syncing… \(viewModel.remainingBlocks) blocks remaining"
                                    )
                                )
                            )
                                .font(.caption)
                                .foregroundColor(
                                    viewModel.isSynced
                                    ? .secondary
                                    : (viewModel.remainingBlocks <= 5 ? .secondary : .primary)
                                )
                        }

                        HStack {
                            Text("Policy")
                            Spacer()
                            Text(MoneroConfig.networkPolicy == .clearnet ? "Clearnet only" : (MoneroConfig.networkPolicy == .i2p ? "I2P only" : "Scan clearnet, broadcast I2P"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Scan")
                            Spacer()
                            Text(MoneroConfig.scanNodeURL())
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

                        if (MoneroConfig.networkPolicy == .i2p || MoneroConfig.networkPolicy == .hybrid), let proxy = MoneroConfig.i2pHTTPProxyAddress {
                            HStack {
                                Text("I2P Proxy")
                                Spacer()
                                Text(proxy)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                    // Refresh Button
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

                        Button(action: {
                            showSend = true
                        }) {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text("Send")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }

                        Button(action: {
                            showReceive = true
                        }) {
                            HStack {
                                Image(systemName: "qrcode")
                                Text("Receive")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(12)
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
            .navigationTitle("Monero Wallet")
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
    @State private var useI2P: Bool
    @State private var i2pRPCAddress: String
    @State private var i2pProxyAddress: String
    @State private var gapLimitInput: String
    @State private var scanModeIsAuto: Bool
    @State private var networkPolicyIndex: Int
    @State private var parInput: String
    @State private var batchInput: String
    @Environment(\.dismiss) var dismiss

    init(viewModel: WalletViewModel) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._nodeAddress = State(initialValue: MoneroConfig.daemonAddress)
        self._useI2P = State(initialValue: MoneroConfig.useI2P)
        self._i2pRPCAddress = State(initialValue: MoneroConfig.i2pRPCAddress)
        self._i2pProxyAddress = State(initialValue: MoneroConfig.i2pHTTPProxyAddress ?? "192.168.4.137:4444")
        let heightValue = viewModel.restoreHeight
        self._rescanHeightInput = State(initialValue: heightValue == 0 ? "" : String(heightValue))
        self._gapLimitInput = State(initialValue: String(MoneroConfig.gapLimit))
        self._scanModeIsAuto = State(initialValue: MoneroConfig.scanMode == .auto)
        let policyIndex: Int
        switch MoneroConfig.networkPolicy {
        case .clearnet: policyIndex = 0
        case .i2p: policyIndex = 1
        case .hybrid: policyIndex = 2
        }
        self._networkPolicyIndex = State(initialValue: policyIndex)
        self._parInput = State(initialValue: String(MoneroConfig.scanParallelism))
        self._batchInput = State(initialValue: String(MoneroConfig.scanBatchSize))
    }

    private var isRescanInProgress: Bool {
        viewModel.isRefreshing
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Network & Node")) {
                    Picker("Network Policy", selection: $networkPolicyIndex) {
                        Text("Clearnet only").tag(0)
                        Text("I2P only").tag(1)
                        Text("Scan clearnet, broadcast I2P").tag(2)
                    }
                    .pickerStyle(.segmented)

                    Group {
                        let scanDesc = (networkPolicyIndex == 1) ? "I2P" : "clearnet"
                        let broadcastDesc = (networkPolicyIndex == 0) ? "clearnet" : "I2P"
                        Text("Scanning over \(scanDesc); broadcasting over \(broadcastDesc).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if networkPolicyIndex == 0 || networkPolicyIndex == 2 {
                        TextField("Clearnet hostname:port", text: $nodeAddress)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Example: 192.168.4.137:18081\n(Full URL will be: http://192.168.4.137:18081)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if networkPolicyIndex == 1 || networkPolicyIndex == 2 {
                        TextField("I2P RPC (.b32.i2p:port)", text: $i2pRPCAddress)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Example: cvxtgqj...b32.i2p:18089")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("I2P HTTP proxy (host:port)", text: $i2pProxyAddress)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Example: 192.168.4.137:4444")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Section(header: Text("Scanning")) {
                        Toggle("Scan Mode: Auto", isOn: $scanModeIsAuto)
                        TextField("Gap limit (1-100000)", text: $gapLimitInput)
                            .keyboardType(.numberPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Text("Controls how many subaddresses are scanned")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(role: .destructive) {
                            do {
                                try WalletManager.shared.clearScanCache()
                            } catch {
                                print("⚠️ Clear cache failed: \(error)")
                            }
                        } label: {
                            Text("Clear scan cache (this network)")
                        }
                    }
                    if !scanModeIsAuto {
                        Section(header: Text("Advanced Scan Tuning")) {
                            TextField("Parallel workers (0-64)", text: $parInput)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            TextField("Batch size (50-5000)", text: $batchInput)
                                .keyboardType(.numberPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("Increase speed on catch-up. Start with 6 workers and 600 batch. 0 workers disables parallelism.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                        switch networkPolicyIndex {
                        case 0: // Clearnet only
                            MoneroConfig.setNetworkPolicy(.clearnet)
                            MoneroConfig.setDaemonAddress(nodeAddress)
                            MoneroConfig.setI2PHTTPProxyAddress(nil)
                        case 1: // I2P only
                            MoneroConfig.setNetworkPolicy(.i2p)
                            MoneroConfig.setI2PRPCAddress(i2pRPCAddress)
                            MoneroConfig.setI2PHTTPProxyAddress(i2pProxyAddress)
                        case 2: // Hybrid (scan clearnet, broadcast I2P)
                            MoneroConfig.setNetworkPolicy(.hybrid)
                            MoneroConfig.setDaemonAddress(nodeAddress)
                            MoneroConfig.setI2PRPCAddress(i2pRPCAddress)
                            MoneroConfig.setI2PHTTPProxyAddress(i2pProxyAddress)
                        default:
                            break
                        }
                        if let gap = parsedGapLimit() {
                            MoneroConfig.setGapLimit(gap)
                            Task {
                                if let id = await WalletManager.shared.getCurrentWalletId() {
                                    try? WalletCoreFFIClient.setGapLimit(walletId: id, gapLimit: gap)
                                }
                            }
                        }
                        // Scan mode and tuning
                        MoneroConfig.setScanMode(scanModeIsAuto ? .auto : .manual)
                        if !scanModeIsAuto {
                            if let p = Int(parInput) {
                                let clamped = max(0, min(p, 64))
                                MoneroConfig.setScanParallelism(clamped)
                            }
                            if let b = Int(batchInput) {
                                let clamped = max(50, min(b, 5000))
                                MoneroConfig.setScanBatchSize(clamped)
                            }
                        }
                        dismiss()
                    }
                }
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
