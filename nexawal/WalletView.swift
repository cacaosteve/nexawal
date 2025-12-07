//
//  WalletView.swift
//  nexawal
//
//  Main wallet view showing balance and address
//

import SwiftUI

struct WalletView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var showSettings: Bool = false
    @State private var showReceive: Bool = false

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
                            Text(viewModel.isSynced ? "Wallet is fully synced" : "Syncing… \(viewModel.remainingBlocks) blocks remaining")
                                .font(.caption)
                                .foregroundColor(viewModel.isSynced ? .secondary : .primary)
                        }

                        HStack {
                            Text("Node")
                            Spacer()
                            Text(MoneroConfig.nodeURL())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
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
    @Environment(\.dismiss) var dismiss

    init(viewModel: WalletViewModel) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._nodeAddress = State(initialValue: MoneroConfig.daemonAddress)
        let heightValue = viewModel.restoreHeight
        self._rescanHeightInput = State(initialValue: heightValue == 0 ? "" : String(heightValue))
    }

    private var isRescanInProgress: Bool {
        viewModel.isRefreshing
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Monero Node Configuration")) {
                    TextField("hostname:port", text: $nodeAddress)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Example: 192.168.4.137:18081\n(Full URL will be: http://192.168.4.137:18081)")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        MoneroConfig.setDaemonAddress(nodeAddress)
                        dismiss()
                    }
                }
            }
        }
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
