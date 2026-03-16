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
            .navigationTitle("Receive XMR")
            .sheet(isPresented: $showShareSheet) {
                ActivityView(activityItems: [moneroURI])
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        copyAddress()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy Address")
                }
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
            Text("Receive Monero")
                .font(.title2)
                .fontWeight(.bold)
            Text("Show the QR code, copy the address, or create a fresh receive address for better privacy.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subaddressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receive Address")
                .font(.headline)

            if viewModel.receiveSubaddresses.isEmpty {
                Text("Loading addresses…")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    private var qrSection: some View {
        VStack(spacing: 16) {
            Text("Scan to Pay")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            QRCodeView(message: moneroURI)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)

            Text(moneroURI)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Address")
                .font(.headline)
            Text(viewModel.currentReceiveAddress())
                .font(addressFont)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .textSelection(.enabled)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var amountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Payment Request (optional)")
                .font(.headline)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Amount (XMR)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("0.0000", text: $amountInput)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Note for the payer", text: $descriptionInput)
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(true)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var actionSection: some View {
        VStack(spacing: 12) {
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

    private var copyConfirmation: some View {
        Text("Address copied to clipboard")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.1))
            .foregroundColor(.green)
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

        guard let outputImage = QRCodeView.filter.outputImage else {
            return nil
        }

        let scaleX = targetSize.width / outputImage.extent.size.width
        let scaleY = targetSize.height / outputImage.extent.size.height
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: max(scaleX, 10), y: max(scaleY, 10)))

        guard let cgImage = QRCodeView.context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
