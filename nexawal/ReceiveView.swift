import SwiftUI
import CoreImage.CIFilterBuiltins

struct ReceiveView: View {
    @ObservedObject var viewModel: WalletViewModel

    @State private var amountInput: String = ""
    @State private var descriptionInput: String = ""
    @State private var showCopyConfirmation: Bool = false
    @State private var showShareSheet: Bool = false

    // Subaddress UI
    @State private var showCreateSubaddressPrompt: Bool = false
    @State private var newSubaddressLabel: String = ""

    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    private let addressFont = Font.system(.caption, design: .monospaced)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    heroSection
                    qrSection
                    addressSection
                    actionSection
                    subaddressSection
                    amountSection
                    if showCopyConfirmation {
                        copyConfirmation
                    }
                }
                .padding()
            }
            .navigationTitle(classicUI ? "RECEIVE" : "Receive XMR")
            .navigationBarTitleDisplayMode(.inline)
            .background((classicPalette?.background ?? Color(.systemBackground)).ignoresSafeArea())
            .tint(classicPalette?.accent ?? .accentColor)
            .scrollContentBackground(classicUI ? .hidden : .automatic)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(classicUI ? "RECEIVE" : "Receive XMR")
                        .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                        .foregroundStyle(classicPalette?.primaryText ?? .primary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        copyAddress()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .foregroundStyle(classicPalette?.accent ?? .accentColor)
                    .accessibilityLabel("Copy Address")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityView(activityItems: [moneroURI])
            }
        }
        .onAppear {
            Task { await viewModel.loadReceiveSubaddresses() }
        }
        .alert("New address label (optional)", isPresented: $showCreateSubaddressPrompt) {
            TextField("Label", text: $newSubaddressLabel)
            Button("Cancel", role: .cancel) {
                newSubaddressLabel = ""
            }
            Button("Create") {
                let label = newSubaddressLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                newSubaddressLabel = ""
                Task { await viewModel.createNewReceiveSubaddress(label: label) }
            }
        } message: {
            Text("A new receive address (subaddress) will be generated for privacy.")
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(classicUI ? "RECEIVE XMR" : "Receive Monero")
                .font(classicUI ? .system(.title2, design: .monospaced).weight(.bold) : .title2.weight(.bold))
                .foregroundColor(classicPalette?.primaryText ?? .primary)
            Text("Show the QR code, copy the address, or create a fresh receive address for better privacy.")
                .font(classicUI ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundColor(classicPalette?.secondaryText ?? .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subaddressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receive Address")
                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                .foregroundStyle(classicPalette?.primaryText ?? .primary)

            if viewModel.receiveSubaddresses.isEmpty {
                Text("Loading addresses…")
                    .font(.caption)
                    .foregroundStyle(classicPalette?.secondaryText ?? .secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Address", selection: $viewModel.selectedReceiveSubaddressIndex) {
                        ForEach(viewModel.receiveSubaddresses, id: \.subaddressIndex) { e in
                            let label = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
                            let title = label.isEmpty ? "Subaddress \(e.subaddressIndex)" : label
                            Text(title).tag(e.subaddressIndex)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(classicPalette?.accent ?? .accentColor)

                    if classicUI, let palette = classicPalette {
                        Button {
                            showCreateSubaddressPrompt = true
                        } label: {
                            Label("New Address", systemImage: "plus.circle")
                                .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            showCreateSubaddressPrompt = true
                        } label: {
                            Label("New Address", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var qrSection: some View {
        VStack(spacing: 16) {
            Text(classicUI ? "SCAN TO PAY" : "Scan to Pay")
                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                .foregroundColor(classicPalette?.primaryText ?? .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            QRCodeView(message: moneroURI)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(classicUI ? (classicPalette?.background ?? .black) : Color.white)
                .cornerRadius(classicUI ? 4 : 12)
                .overlay(
                    RoundedRectangle(cornerRadius: classicUI ? 4 : 12)
                        .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
                )
                .shadow(color: classicUI ? .clear : Color.black.opacity(0.1), radius: 8, x: 0, y: 4)

            Text(moneroURI)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(classicPalette?.secondaryText ?? .secondary)
                .textSelection(.enabled)
        }
        .padding()
        .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
        )
        .cornerRadius(classicUI ? 4 : 16)
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(classicUI ? "ADDRESS" : "Address")
                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                .foregroundColor(classicPalette?.primaryText ?? .primary)
            Text(viewModel.currentReceiveAddress())
                .font(addressFont)
                .foregroundColor(classicPalette?.primaryText ?? .primary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: classicUI ? 4 : 8)
                        .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
                )
                .cornerRadius(classicUI ? 4 : 8)
                .textSelection(.enabled)
        }
        .padding()
        .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
        )
        .cornerRadius(classicUI ? 4 : 16)
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(classicUI ? "PAYMENT REQUEST (OPTIONAL)" : "Payment Request (optional)")
                .font(classicUI ? .system(.headline, design: .monospaced).weight(.bold) : .headline)
                .foregroundColor(classicPalette?.primaryText ?? .primary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Amount (XMR)")
                        .font(classicUI ? .system(.subheadline, design: .monospaced) : .subheadline)
                        .foregroundColor(classicPalette?.secondaryText ?? .secondary)
                    TextField("0.0000", text: $amountInput)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .foregroundColor(classicPalette?.primaryText)
                        .padding(12)
                        .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: classicUI ? 4 : 8)
                                .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
                        )
                        .cornerRadius(classicUI ? 4 : 8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(classicUI ? .system(.subheadline, design: .monospaced) : .subheadline)
                        .foregroundColor(classicPalette?.secondaryText ?? .secondary)
                    TextField("Note for the payer", text: $descriptionInput)
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(true)
                        .foregroundColor(classicPalette?.primaryText)
                        .padding(12)
                        .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: classicUI ? 4 : 8)
                                .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
                        )
                        .cornerRadius(classicUI ? 4 : 8)
                }
            }
        }
        .padding()
        .background(classicPalette?.panel ?? Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: classicUI ? 4 : 16)
                .stroke(classicPalette?.border ?? Color.clear, lineWidth: classicUI ? 1 : 0)
        )
        .cornerRadius(classicUI ? 4 : 16)
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
            if classicUI, let palette = classicPalette {
                Button(action: copyAddress) {
                    Label("Copy Address", systemImage: "doc.on.doc")
                        .neonCTAStyle(classicUI: true, palette: palette)
                }
                .buttonStyle(.plain)

                if #available(iOS 16.0, *) {
                    ShareLink(item: moneroURI) {
                        Label("Share Payment Link", systemImage: "square.and.arrow.up")
                            .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share Payment Link", systemImage: "square.and.arrow.up")
                            .neonSecondaryButtonStyle(classicUI: true, palette: palette)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: copyAddress) {
                    Label("Copy Address", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if #available(iOS 16.0, *) {
                    ShareLink(item: moneroURI) {
                        Label("Share Payment Link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share Payment Link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var copyConfirmation: some View {
        Text("Address copied to clipboard")
            .font(classicUI ? .system(.footnote, design: .monospaced) : .footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((classicPalette?.success ?? .green).opacity(0.15))
            .foregroundColor(classicPalette?.success ?? .green)
            .cornerRadius(8)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var moneroURI: String {
        var base = "monero:\(viewModel.currentReceiveAddress())"
        var components: [String] = []

        if let amountString = sanitizedAmountString {
            components.append("tx_amount=\(amountString)")
        }

        let descriptor = descriptionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !descriptor.isEmpty {
            let encoded = descriptor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? descriptor
            components.append("tx_description=\(encoded)")
        }

        if !components.isEmpty {
            base += "?" + components.joined(separator: "&")
        }

        return base
    }

    private var sanitizedAmountString: String? {
        let trimmed = amountInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Ensure valid decimal with up to 12 fractional digits
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 12
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal

        guard let decimal = Decimal(string: trimmed, locale: formatter.locale), decimal > 0 else {
            return nil
        }

        return formatter.string(from: decimal as NSDecimalNumber)
    }

    private func copyAddress() {
        UIPasteboard.general.string = viewModel.currentReceiveAddress()
        withAnimation {
            showCopyConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }
}

// MARK: - QR Code Rendering

private struct QRCodeView: View {
    let message: String
    @Environment(\.classicUI) private var classicUI
    @Environment(\.classicPalette) private var classicPalette

    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        GeometryReader { proxy in
            if let image = generateQRCode(for: message, targetSize: proxy.size) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.width)
            } else {
                Color.secondary
                    .overlay(
                        Image(systemName: "xmark.octagon")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(minHeight: 200)
    }

    private func generateQRCode(for string: String, targetSize: CGSize) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let data = Data(string.utf8)
        QRCodeView.filter.setValue(data, forKey: "inputMessage")
        QRCodeView.filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = QRCodeView.filter.outputImage else {
            return nil
        }

        let scaleX = targetSize.width / outputImage.extent.size.width
        let scaleY = targetSize.height / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: max(scaleX, 10), y: max(scaleY, 10)))

        let colored: CIImage
        if classicUI, let palette = classicPalette {
            // Neon modules on matching background (scannable green-on-black / dark-green-on-light).
            let falseColor = CIFilter.falseColor()
            falseColor.inputImage = scaledImage
            falseColor.color0 = CIColor(color: UIColor(palette.accent)) // QR modules (was black)
            falseColor.color1 = CIColor(color: UIColor(palette.background)) // quiet zone (was white)
            colored = falseColor.outputImage ?? scaledImage
        } else {
            colored = scaledImage
        }

        guard let cgImage = QRCodeView.context.createCGImage(colored, from: colored.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
