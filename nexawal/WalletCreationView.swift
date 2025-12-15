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

    // Single-wallet UX: confirm before replacing any existing stored wallet on device.
    @State private var showReplaceConfirm: Bool = false
    @State private var hasStoredWallet: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Wallet Setup")) {
                    Text("Enter your 25-word mnemonic phrase to create or import a wallet")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $mnemonicInput)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .focused($isMnemonicFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Restore Height:")
                            TextField("0", text: $restoreHeightInput)
                                .keyboardType(.numberPad)
                        }

                        // Guidance: restore height is critical for correctness and UX.
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
        }
    }

    private func createOrImport(isReplace: Bool) async {
        let height = UInt64(restoreHeightInput) ?? 0
        if isReplace {
            await viewModel.replaceWallet(
                mnemonic: mnemonicInput,
                restoreHeight: height,
                mainnet: isMainnet
            )
        } else {
            await viewModel.createWallet(
                mnemonic: mnemonicInput,
                restoreHeight: height,
                mainnet: isMainnet
            )
        }

        // After importing/replacing, refresh persisted-wallet flag.
        hasStoredWallet = await viewModel.hasStoredWallet()
    }
}
