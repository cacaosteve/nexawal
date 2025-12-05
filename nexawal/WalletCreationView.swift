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
                    
                    HStack {
                        Text("Restore Height:")
                        TextField("0", text: $restoreHeightInput)
                            .keyboardType(.numberPad)
                    }
                    
                    Toggle("Mainnet", isOn: $isMainnet)
                }
                
                Section {
                    Button(action: {
                        Task {
                            let height = UInt64(restoreHeightInput) ?? 0
                            await viewModel.createWallet(
                                mnemonic: mnemonicInput,
                                restoreHeight: height,
                                mainnet: isMainnet
                            )
                        }
                    }) {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                            Text(viewModel.isLoading ? "Creating Wallet..." : "Create/Import Wallet")
                        }
                    }
                    .disabled(viewModel.isLoading || mnemonicInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    }
}

