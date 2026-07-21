//
//  WalletCreationView.swift
//  nexawal
//
//  View for creating or importing a wallet from mnemonic
//

import SwiftUI
import MoneroWalletCoreFFI

struct WalletCreationView: View {
    @ObservedObject var viewModel: WalletViewModel
    @State private var mnemonicInput: String = ""
    @State private var restoreHeightInput: String = "0"
    @State private var isMainnet: Bool = true
    @FocusState private var isMnemonicFocused: Bool
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    enum WalletSetupMode: String, CaseIterable, Identifiable {
        case create = "Create new wallet (fast)"
        case `import` = "Import existing wallet"
        var id: String { rawValue }
    }

    // Create-mode seed backup gate: the app generates the mnemonic (never a user paste),
    // forces an explicit "I wrote it down" confirmation, then re-checks a few random words
    // before Create is enabled.
    @State private var generatedMnemonic: String = ""
    @State private var wroteSeedDown: Bool = false
    @State private var seedChallengeIndices: [Int] = []
    @State private var seedChallengeAnswers: [String] = ["", "", ""]
    @State private var seedGenerationError: String?
    @FocusState private var focusedChallengeIndex: Int?

    @State private var setupMode: WalletSetupMode = .import

    // Import scan tuning presets (for experiments / quick switching)


    // Fast-restore-height (create mode only): we fetch daemon height info and set
    // restoreHeight = node tip - 10.
    @State private var suggestedRestoreHeight: UInt64?
    @State private var isFetchingSuggestedHeight: Bool = false
    @State private var suggestedHeightError: String?

    // Single-wallet UX: confirm before replacing any existing stored wallet on device.
    @State private var showReplaceConfirm: Bool = false
    @State private var hasStoredWallet: Bool = false
    @State private var requireBiometrics: Bool = false
    @State private var biometricsAvailable: Bool = false
    @State private var biometricsEnrolled: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: NeonSectionHeader(title: "Wallet Setup")) {
                    Text("Choose whether you’re creating a brand new wallet (fast sync) or importing an existing wallet (full scan unless you set a restore height).")
                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

                    if classicUI, let palette = classicPalette {
                        neonSetupModePicker(palette: palette)
                    } else {
                        Picker("Mode", selection: $setupMode) {
                            ForEach(WalletSetupMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    switch setupMode {
                    case .create:
                        seedBackupGateView
                    case .import:
                        TextEditor(text: $mnemonicInput)
                            .frame(minHeight: 120)
                            .font(.system(.body, design: .monospaced))
                            .focused($isMnemonicFocused)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    // Restore height controls:
                    // - Create mode: hide the editable field (fast restore height is applied automatically when restoreHeightInput == 0)
                    // - Import mode: show editable restore height (critical for correctness)
                    switch setupMode {
                    case .create:
                        VStack(alignment: .leading, spacing: 6) {
                            if isFetchingSuggestedHeight {
                                Text("Starting height: fetching from node…")
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                            } else if let suggested = suggestedRestoreHeight {
                                Text("Starting height (fast): \(suggested) (node tip − 10)")
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                            } else {
                                Text("Starting height (fast): unavailable (will use 0)")
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                            }

                            if let msg = suggestedHeightError {
                                Text(msg)
                                    .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                            }
                        }

                    case .import:
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Restore Height:")
                                    TextField("0", text: $restoreHeightInput)
                                        .keyboardType(.numberPad)
                                }

                                let height = UInt64(restoreHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                                if height == 0 {
                                    Text("Tip: 0 scans the full chain history. This is the safest option if you’re unsure, but it can take longer to sync.")
                                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                                } else {
                                    Text("Warning: If you set a restore height after your first transaction, older funds will not appear until you rescan from an earlier height.")
                                        .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                                }
                            }
                        }
                    }

                    NeonToggle(title: "Mainnet", isOn: $isMainnet)

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
                    }
                }

                Section {
                    if hasStoredWallet {
                        Button(action: {
                            Task { await viewModel.unlockStoredWallet() }
                        }) {
                            HStack {
                                if viewModel.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                }
                                Text(viewModel.isLoading ? "Unlocking Wallet..." : "Unlock Existing Wallet")
                            }
                        }
                        .disabled(viewModel.isLoading)
                    }

                    if setupMode == .import {
                        VStack(spacing: 10) {
                            Button(action: {
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
                                    Text(viewModel.isLoading ? "Importing Wallet..." : "Import Wallet")
                                }
                            }
                            .disabled(viewModel.isLoading || mnemonicInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
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
                                Text(viewModel.isLoading ? "Creating Wallet..." : "Create Wallet")
                            }
                        }
                        .disabled(viewModel.isLoading || !isSeedBackupGatePassed())
                    }
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
                            .foregroundColor(classicPalette?.danger ?? .red)
                            .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                    }
                }

                Section(header: NeonSectionHeader(title: "Info")) {
                    HStack {
                        Text("WalletCore Version:")
                            .foregroundColor(classicPalette?.secondaryText)
                        Spacer()
                        Text(viewModel.getVersion())
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(classicPalette?.primaryText)
                    }

                    HStack {
                        Text("Node Address:")
                            .foregroundColor(classicPalette?.secondaryText)
                        Spacer()
                        Text(MoneroConfig.daemonAddress)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(classicPalette?.secondaryText ?? .secondary)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(classicUI ? "NEXAWAL" : "Create Wallet")
                        .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                        .tracking(classicUI ? 2 : 0)
                }
            }
            .neonFormChrome(classicUI: classicUI, palette: classicPalette)
            .tint(classicPalette?.accent ?? .accentColor)
        }
        .task {
            // Authoritative: check persisted wallet presence (metadata) rather than in-memory UI state.
            hasStoredWallet = await viewModel.hasStoredWallet()
            let availability = await viewModel.biometricAvailability()
            biometricsAvailable = availability.available
            biometricsEnrolled = availability.enrolled
            requireBiometrics = availability.available && availability.enrolled

            // Best-effort: fetch suggested restore height for create mode.
            // This is UI-only guidance; actual application happens in createOrImport().
            await refreshSuggestedRestoreHeightIfNeeded()

            if setupMode == .create {
                generateNewSeed()
            }
        }
        .onChange(of: setupMode) {
            Task { await refreshSuggestedRestoreHeightIfNeeded() }
            if setupMode == .create, generatedMnemonic.isEmpty {
                generateNewSeed()
            }
        }
        .onChange(of: isMainnet) {
            Task { await refreshSuggestedRestoreHeightIfNeeded() }
        }
    }

    // MARK: - Neon setup mode picker

    @ViewBuilder
    private func neonSetupModePicker(palette: ClassicPalette) -> some View {
        HStack(spacing: 0) {
            ForEach(WalletSetupMode.allCases) { mode in
                let selected = setupMode == mode
                Button {
                    setupMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(selected ? palette.ctaText : palette.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selected ? palette.cta : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.card)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Create-mode seed backup gate

    @ViewBuilder
    private var seedBackupGateView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This is your recovery seed. Write it down on paper and store it somewhere safe. Anyone with these words can access your funds — nexawal never uploads or backs it up for you.")
                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

            mnemonicWordGrid

            if let seedGenerationError {
                Text(seedGenerationError)
                    .font(.caption)
                    .foregroundColor(classicPalette?.danger ?? .red)
            }

            Button(action: { generateNewSeed() }) {
                Text("Generate new seed")
            }
            .disabled(viewModel.isLoading)

            NeonToggle(title: "I wrote down my recovery seed", isOn: $wroteSeedDown)
                .disabled(generatedMnemonic.isEmpty)

            if wroteSeedDown {
                seedChallengeView
            }
        }
    }

    private var mnemonicWordGrid: some View {
        let words = generatedMnemonic.split(separator: " ").map(String.init)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 4) {
                    Text("\(index + 1).")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(word)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .textSelection(.disabled)
    }

    private var seedChallengeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm you wrote it down: enter the requested words below.")
                .font(classicUI ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(classicPalette?.secondaryText ?? .secondary)

            ForEach(Array(seedChallengeIndices.enumerated()), id: \.offset) { i, wordIndex in
                HStack {
                    Text("Word #\(wordIndex + 1):")
                        .font(.system(.body, design: .monospaced))
                    TextField("", text: challengeBinding(for: i))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedChallengeIndex, equals: i)
                }
            }

            if !seedChallengeIndices.isEmpty, !allChallengesMatch() {
                Text("Word(s) don't match yet.")
                    .font(.caption)
                    .foregroundColor(classicPalette?.danger ?? .red)
            }
        }
    }

    private func challengeBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { seedChallengeAnswers.indices.contains(index) ? seedChallengeAnswers[index] : "" },
            set: { newValue in
                guard seedChallengeAnswers.indices.contains(index) else { return }
                seedChallengeAnswers[index] = newValue
            }
        )
    }

    private func generateNewSeed() {
        seedGenerationError = nil
        do {
            generatedMnemonic = try WalletCoreFFIClient.generateMnemonicEnglish()
        } catch {
            generatedMnemonic = ""
            seedGenerationError = "Couldn’t generate a seed: \(error.localizedDescription)"
        }
        wroteSeedDown = false
        seedChallengeAnswers = ["", "", ""]
        regenerateChallenges()
    }

    private func regenerateChallenges() {
        let wordCount = generatedMnemonic.split(separator: " ").count
        guard wordCount >= 3 else {
            seedChallengeIndices = []
            return
        }
        var indices = Set<Int>()
        while indices.count < 3 {
            indices.insert(Int.random(in: 0..<wordCount))
        }
        seedChallengeIndices = indices.sorted()
        seedChallengeAnswers = ["", "", ""]
    }

    private func allChallengesMatch() -> Bool {
        let words = generatedMnemonic.split(separator: " ").map(String.init)
        guard !seedChallengeIndices.isEmpty, seedChallengeIndices.count == seedChallengeAnswers.count else { return false }
        for (i, wordIndex) in seedChallengeIndices.enumerated() {
            guard words.indices.contains(wordIndex) else { return false }
            let expected = words[wordIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let actual = seedChallengeAnswers[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !actual.isEmpty, actual == expected else { return false }
        }
        return true
    }

    private func isSeedBackupGatePassed() -> Bool {
        !generatedMnemonic.isEmpty && wroteSeedDown && allChallengesMatch()
    }

    private func createOrImport(isReplace: Bool) async {
        // For create mode, we hide the restore height input and use the suggested height.
        // For import mode, we take the user's input.
        let rawHeight = UInt64(restoreHeightInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let effectiveHeight: UInt64 = {
            // Feather-style optimization: for *new wallets only*, if the user leaves restore
            // height at 0, use a fast restore height near tip: node tip - 10.
            if setupMode == .create, rawHeight == 0, let suggested = suggestedRestoreHeight {
                return suggested
            }
            return rawHeight
        }()

        let effectiveMnemonic = (setupMode == .create) ? generatedMnemonic : mnemonicInput

        if isReplace {
            await viewModel.replaceWallet(
                mnemonic: effectiveMnemonic,
                restoreHeight: effectiveHeight,
                mainnet: isMainnet,
                requireBiometrics: requireBiometrics
            )
        } else {
            await viewModel.createWallet(
                mnemonic: effectiveMnemonic,
                restoreHeight: effectiveHeight,
                mainnet: isMainnet,
                requireBiometrics: requireBiometrics
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

        // Fetch daemon height info and compute restoreHeight = node tip - 10.
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
