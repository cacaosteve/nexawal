//
//  ContentView.swift
//  nexawal
//
//  Created by steve on 12/1/25.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WalletViewModel

    var body: some View {
        Group {
            if viewModel.isWalletOpen {
                WalletView(viewModel: viewModel)
            } else {
                WalletCreationView(viewModel: viewModel)
            }
        }
        .task {
            // WalletViewModel handles loading any stored wallet on launch.
        }
    }
}

#Preview {
    ContentView(viewModel: WalletViewModel())
}
