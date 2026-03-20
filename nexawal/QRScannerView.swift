import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, dismiss: dismiss)
    }
    
    class Coordinator: NSObject, QRScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let dismiss: DismissAction
        
        init(onScan: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onScan = onScan
            self.dismiss = dismiss
        }
        
        func didFindCode(_ code: String) {
            dismiss()
            onScan(code)
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func didFindCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerViewControllerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkCameraPermission()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showCameraUnavailable("Camera permission denied")
                    }
                }
            }
        case .denied, .restricted:
            showCameraUnavailable("Camera access denied")
        @unknown default:
            showCameraUnavailable("Unknown camera permission status")
        }
    }
    
    private func setupCamera() {
        #if targetEnvironment(simulator)
        showCameraUnavailable("Camera not available on simulator")
        return
        #else
        let session = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showCameraUnavailable("No camera found")
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            showCameraUnavailable("Could not access camera: \(error.localizedDescription)")
            return
        }
        
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        } else {
            showCameraUnavailable("Could not add camera input")
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            showCameraUnavailable("Could not add metadata output")
            return
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        self.previewLayer = previewLayer
        self.captureSession = session
        
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        
        addOverlay()
        #endif
    }
    
    private func addOverlay() {
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = .clear
        view.addSubview(overlayView)
        
        let scanAreaSize: CGFloat = 250
        let scanAreaOrigin = CGPoint(
            x: (view.bounds.width - scanAreaSize) / 2,
            y: (view.bounds.height - scanAreaSize) / 2
        )
        let scanArea = CGRect(origin: scanAreaOrigin, size: CGSize(width: scanAreaSize, height: scanAreaSize))
        
        let path = UIBezierPath(rect: view.bounds)
        let scanPath = UIBezierPath(roundedRect: scanArea, cornerRadius: 12)
        path.append(scanPath)
        path.usesEvenOddFillRule = true
        
        let fillLayer = CAShapeLayer()
        fillLayer.path = path.cgPath
        fillLayer.fillRule = .evenOdd
        fillLayer.fillColor = UIColor.black.withAlphaComponent(0.5).cgColor
        overlayView.layer.addSublayer(fillLayer)
        
        let borderLayer = CAShapeLayer()
        borderLayer.path = scanPath.cgPath
        borderLayer.strokeColor = UIColor.white.cgColor
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 3
        overlayView.layer.addSublayer(borderLayer)
        
        let instructionLabel = UILabel()
        instructionLabel.text = "Scan Monero QR code"
        instructionLabel.textColor = .white
        instructionLabel.font = .systemFont(ofSize: 17, weight: .medium)
        instructionLabel.textAlignment = .center
        instructionLabel.frame = CGRect(x: 0, y: scanArea.maxY + 24, width: view.bounds.width, height: 24)
        overlayView.addSubview(instructionLabel)
        
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        cancelButton.frame = CGRect(x: 20, y: view.bounds.height - 60, width: 80, height: 44)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        overlayView.addSubview(cancelButton)
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
    
    private func showCameraUnavailable(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.frame = CGRect(x: 20, y: (view.bounds.height - 100) / 2, width: view.bounds.width - 40, height: 100)
        view.addSubview(label)
        
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.frame = CGRect(x: (view.bounds.width - 80) / 2, y: view.bounds.height - 100, width: 80, height: 44)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first,
           let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
           let stringValue = readableObject.stringValue {
            captureSession?.stopRunning()
            delegate?.didFindCode(stringValue)
        }
    }
}
