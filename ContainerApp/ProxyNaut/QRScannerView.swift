import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
import AudioToolbox

struct QRScannerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onScan: (String) -> Void
    
    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        let parent: QRScannerView
        
        init(parent: QRScannerView) {
            self.parent = parent
        }
        
        func didFindCode(_ code: String) {
            parent.onScan(code)
            parent.dismiss()
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didFindCode(_ code: String)
}

class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        checkCameraPermission()
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCamera()
                    }
                }
            }
        default:
            showPermissionDenied()
        }
    }
    
    private func setupCamera() {
        let captureSession = AVCaptureSession()
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else { return }
        
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            }
        } catch {
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        self.previewLayer = previewLayer
        self.captureSession = captureSession
        
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
        
        addOverlay()
    }
    
    private func addOverlay() {
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = .clear
        
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
        borderLayer.strokeColor = UIColor.systemGreen.cgColor
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 3
        overlayView.layer.addSublayer(borderLayer)
        
        let label = UILabel()
        label.text = "Scan QR Code"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: scanArea.maxY + 30, width: view.bounds.width, height: 30)
        overlayView.addSubview(label)
        
        view.addSubview(overlayView)
    }
    
    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: "Camera Access Required",
            message: "Please enable camera access in Settings to scan QR codes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first,
           let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
           let stringValue = readableObject.stringValue {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            delegate?.didFindCode(stringValue)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}
