//
//  WalletCreationView.swift
//  nexawal
//
//  View for creating or importing a wallet from mnemonic
//

import SwiftUI

struct WalletCreationView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var mnemonicInput: String = ""
    @State private var restoreHeightInput: String = "0"
    @State private var isMainnet: Bool = true
    @FocusState private var isMnemonicFocused: Bool

    enum WalletSetupMode: String, CaseIterable, Identifiable {
        case create = "Create new wallet (fast)"
        case `import` = "Import existing wallet (safe)"
        var id: String { rawValue }
    }

    @State private var setupMode: WalletSetupMode = .import

    // Fast-restore-height (create mode only): we fetch daemon get_info and set restoreHeight = target_height - 10.
    @State private var suggestedRestoreHeight: UInt64?
    @State private var isFetchingSuggestedHeight: Bool = false
    @State private var suggestedHeightError: String?

    // Single-wallet UX: confirm before replacing any existing stored wallet on device.
    @State private var showReplaceConfirm: Bool = false
    @State private var hasStoredWallet: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Wallet Setup")) {
                    Text("Choose whether you’re creating a brand new wallet (fast sync) or importing an existing wallet (full scan unless you set a restore height).")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Mode", selection: $setupMode) {
                        ForEach(WalletSetupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $mnemonicInput)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .focused($isMnemonicFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    // Restore height controls:
                    // - Create mode: hide the editable field (fast restore height is applied automatically when restoreHeightInput == 0)
                    // - Import mode: show editable restore height (critical for correctness)
                    switch setupMode {
                    case .create:
                        VStack(alignment: .leading, spacing: 6) {
                            if isFetchingSuggestedHeight {
                                Text("Starting height: fetching from node…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if let suggested = suggestedRestoreHeight {
                                Text("Starting height (fast): \(suggested) (node target_height − 10)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Starting height (fast): unavailable (will use 0)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let msg = suggestedHeightError {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                    case .import:
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Restore Height:")
                                TextField("0", text: $restoreHeightInput)
                                    .keyboardType(.numberPad)
                            }

                            let height = UInt64(restoreHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                            if height == 0 {
                                Text("Tip: 0 scans the full chain history. This is the safest option if you’re unsure, but it can take longer to sync.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Warning: If you set a restore height after your first transaction, older funds will not appear until you rescan from an earlier height.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Toggle("Mainnet", isOn: $isMainnet)
                }

                Section {
                    Button(action: {
                        // If we already have a persisted wallet, confirm before replacing it.
                        if hasStoredWallet {
                            showReplaceConfirm = true
                        } else {
                            Task { await createOrImport(isReplace: false) }
                        }
                    }) {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                            Text(viewModel.isLoading ? "Importing Wallet..." : "Create/Import Wallet")
                        }
                    }
                    .disabled(viewModel.isLoading || mnemonicInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .alert("Replace existing wallet?", isPresented: $showReplaceConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Replace", role: .destructive) {
                        Task { await createOrImport(isReplace: true) }
                    }
                } message: {
                    Text("This will replace the existing wallet on this device.\n\nIf you continue, the currently stored mnemonic and scan state will be removed. Make sure you have your mnemonic backed up before proceeding.")
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section(header: Text("Info")) {
                    HStack {
                        Text("WalletCore Version:")
                        Spacer()
                        Text(viewModel.getVersion())
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Text("Node Address:")
                        Spacer()
                        Text(MoneroConfig.nodeURL())
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Create Wallet")
        }
        .task {
            // Authoritative: check persisted wallet presence (metadata) rather than in-memory UI state.
            hasStoredWallet = await viewModel.hasStoredWallet()

            // Best-effort: fetch suggested restore height for create mode.
            // This is UI-only guidance; actual application happens in createOrImport().
            await refreshSuggestedRestoreHeightIfNeeded()
        }
        .onChange(of: setupMode) { _ in
            Task { await refreshSuggestedRestoreHeightIfNeeded() }
        }
        .onChange(of: isMainnet) { _ in
            Task { await refreshSuggestedRestoreHeightIfNeeded() }
        }
    }

    private func createOrImport(isReplace: Bool) async {
        // For create mode, we hide the restore height input and use the suggested height.
        // For import mode, we take the user's input.
        let rawHeight = UInt64(restoreHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let effectiveHeight: UInt64 = {
            // Feather-style optimization: for *new wallets only*, if the user leaves restore height at 0,
            // use a fast restore height near tip: target_height - 10.
            if setupMode == .create, rawHeight == 0, let suggested = suggestedRestoreHeight {
                return suggested
            }
            return rawHeight
        }()

        if isReplace {
            await viewModel.replaceWallet(
                mnemonic: mnemonicInput,
                restoreHeight: effectiveHeight,
                mainnet: isMainnet
            )
        } else {
            await viewModel.createWallet(
                mnemonic: mnemonicInput,
                restoreHeight: effectiveHeight,
                mainnet: isMainnet
            )
        }

        // After importing/replacing, refresh persisted-wallet flag.
        hasStoredWallet = await viewModel.hasStoredWallet()
    }

    private func refreshSuggestedRestoreHeightIfNeeded() async {
        guard setupMode == .create else {
            suggestedRestoreHeight = nil
            suggestedHeightError = nil
            isFetchingSuggestedHeight = false
            return
        }

        isFetchingSuggestedHeight = true
        suggestedHeightError = nil

        // Fetch daemon get_info and compute restoreHeight = target_height - 10.
        do {
            let baseURL = MoneroConfig.scanNodeURL()

            // If scanning over I2P, route the request through the configured HTTP proxy.
            let proxy: String? = (MoneroConfig.networkPolicy == .i2p) ? MoneroConfig.i2pHTTPProxyAddress : nil

            #if DEBUG
            print("🛰️ Suggested height: policy=\(MoneroConfig.networkPolicy), url=\(baseURL), proxy=\(proxy ?? "(none)")")
            #endif

            let info = try await MoneroDaemonClient.getInfo(baseURL: baseURL, proxyAddress: proxy)
            let tip = info.targetHeight
            let suggested = tip > 10 ? (tip - 10) : 0
            suggestedRestoreHeight = suggested
            suggestedHeightError = nil
        } catch {
            // Non-fatal: this is only used to suggest a fast height.
            suggestedRestoreHeight = nil
            suggestedHeightError = "Couldn’t fetch a fast restore height from the node. Leaving restore height as 0."
            #if DEBUG
            print("🛰️ Suggested height failed: \(error.localizedDescription)")
            #endif
        }

        isFetchingSuggestedHeight = false
    }
}
