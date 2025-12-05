//
//  ContentView.swift
//  nexawal
//
//  Created by steve on 12/1/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = WalletViewModel()
    
    var body: some View {
        Group {
            if viewModel.isWalletOpen {
                WalletView(viewModel: viewModel)
            } else {
                WalletCreationView(viewModel: viewModel)
            }
        }
        .task {
            // Check if wallet is already open on app launch
            // For now, we'll require creating/importing a wallet each session
            // In the future, we can persist wallet state
        }
    }
}

#Preview {
    ContentView()
}
