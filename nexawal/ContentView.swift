//
//  ContentView.swift
//  nexawal
//
//  Created by steve on 12/1/25.
//

import SwiftUI

enum MainTab: Hashable {
    case wallet
    case receive
    case send
    case settings

    var title: String {
        switch self {
        case .wallet: return "Wallet"
        case .receive: return "Receive"
        case .send: return "Send"
        case .settings: return "Settings"
        }
    }

    var neonTitle: String { title.uppercased() }

    var systemImage: String {
        switch self {
        case .wallet: return "house.fill"
        case .receive: return "qrcode"
        case .send: return "paperplane.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: WalletViewModel
    @AppStorage(MoneroConfig.userDefaultsClassicUIKey) private var classicUIEnabled: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: MainTab = .wallet

    var body: some View {
        Group {
            if viewModel.isWalletOpen {
                MainTabView(viewModel: viewModel, selectedTab: $selectedTab)
            } else {
                WalletCreationView(viewModel: viewModel)
            }
        }
        // Classic UI setting ON = non-neon standard look.
        // Setting OFF (default) = neon terminal theme.
        .classicTheme(enabled: !classicUIEnabled, colorScheme: colorScheme)
        .task {
            // WalletViewModel handles loading any stored wallet on launch.
        }
    }
}

/// Bottom tabs matching Android: Wallet → Receive → Send → Settings.
/// Uses a custom tab bar so neon green icons aren't overridden by UITabBar (which stays white).
struct MainTabView: View {
    @ObservedObject var viewModel: WalletViewModel
    @Binding var selectedTab: MainTab
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    private let tabs: [MainTab] = [.wallet, .receive, .send, .settings]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .wallet:
                    WalletView(viewModel: viewModel, selectedTab: $selectedTab)
                case .receive:
                    ReceiveView(viewModel: viewModel)
                case .send:
                    SendView(viewModel: viewModel)
                case .settings:
                    SettingsView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            NeonTabBar(
                tabs: tabs,
                selectedTab: $selectedTab,
                classicUI: classicUI,
                palette: classicPalette
            )
        }
        .background((classicPalette?.background ?? Color(.systemBackground)).ignoresSafeArea())
    }
}

private struct NeonTabBar: View {
    let tabs: [MainTab]
    @Binding var selectedTab: MainTab
    let classicUI: Bool
    let palette: ClassicPalette?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette?.border.opacity(classicUI ? 0.45 : 0) ?? Color(.separator))
                .frame(height: classicUI ? 1 : 0.33)

            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { tab in
                    let selected = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 20, weight: selected ? .semibold : .regular))
                            Text(classicUI ? tab.neonTitle : tab.title)
                                .font(
                                    classicUI
                                        ? .system(size: 10, weight: .semibold, design: .monospaced)
                                        : .system(size: 10, weight: selected ? .semibold : .medium)
                                )
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(itemColor(selected: selected))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .background(barBackground.ignoresSafeArea(edges: .bottom))
        }
    }

    private var barBackground: Color {
        if classicUI, let palette {
            return palette.panel
        }
        return Color(.secondarySystemBackground)
    }

    private func itemColor(selected: Bool) -> Color {
        if classicUI, let palette {
            return selected ? palette.accent : palette.secondaryText
        }
        return selected ? Color.accentColor : Color.secondary
    }
}

#Preview {
    ContentView(viewModel: WalletViewModel())
}
