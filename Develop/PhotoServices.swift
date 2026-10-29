import SwiftUI
import AVFoundation
import Photos
import CoreImage.CIFilterBuiltins
import OSLog

protocol FilmRendering: Sendable {
    func render(_ photo: UIImage, progress: Double) async -> UIImage?
}

protocol CameraProviding: Sendable {
    var session: AVCaptureSession { get }
    func start() async throws
    func stop()
    func capture() async throws -> UIImage
}

/// Serial actor keeps expensive Core Image work off the UI executor.
actor FilmRenderer: FilmRendering {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ photo: UIImage, progress: Double) -> UIImage? {
        guard let cg = photo.cgImage else { return nil }
        // Respect EXIF orientation before cropping; device JPEGs often store rotated pixels.
        let exif: Int32
        switch photo.imageOrientation {
        case .up: exif = 1
        case .upMirrored: exif = 2
        case .down: exif = 3
        case .downMirrored: exif = 4
        case .leftMirrored: exif = 5
        case .right: exif = 6
        case .rightMirrored: exif = 7
        case .left: exif = 8
        @unknown default: exif = 1
        }
        let input = CIImage(cgImage: cg).oriented(forExifOrientation: exif)
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }
        let extent = input.extent
        let ratio: CGFloat = 206 / 192
        let width = min(extent.width, extent.height * ratio)
        let height = width / ratio
        let crop = CGRect(x: extent.midX - width/2, y: extent.midY - height/2, width: width, height: height)
        let normalized = input.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let sized = normalized.transformed(by: CGAffineTransform(scaleX: 824/width, y: 824/width))
        let bounds = sized.extent
        let p = max(0, min(1, progress))
        let controls = CIFilter.colorControls()
        controls.inputImage = sized.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: (1-p) * 16])
        controls.saturation = Float(0.05 + p * 0.8)
        controls.contrast = Float(0.35 + p * 0.67)
        controls.brightness = Float((1-p) * 0.26)
        guard var image = controls.outputImage else { return nil }
        image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6900 + (1-p)*1000, y: 8)])
        if let noise = CIFilter.randomGenerator().outputImage {
            let grain = noise.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.025, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.025, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0.025, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.12)])
            image = grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        guard let cg = context.createCGImage(image, from: bounds) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum CameraFailure: LocalizedError {
    case unavailable, capture, rendering, denied, restricted, interrupted, photosDenied
    var errorDescription: String? { switch self {
        case .unavailable: "Camera unavailable. You can still use the illustrated sample."
        case .capture: "The photo couldn’t be captured. Please try again."
        case .rendering: "This image couldn’t be developed. Please try again."
        case .denied: "Camera access is off. You can enable it in Settings or keep using the sample."
        case .restricted: "Camera access is restricted on this iPhone. You can still use the sample."
        case .interrupted: "The camera is temporarily unavailable. Try again or use the sample."
        case .photosDenied: "Allow weecam to add photos in Settings to save this print. Your print is still here."
        } }
}

final class CameraService: NSObject, AVCapturePhotoCaptureDelegate, CameraProviding, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "weecam.camera")
    private let output = AVCapturePhotoOutput()
    private var pending: CheckedContinuation<UIImage, Error>?
    private var configured = false
    private var pendingID: UUID?
    private var pendingPhotoID: Int64?

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraFailure.denied }
        case .denied: throw CameraFailure.denied
        case .restricted: throw CameraFailure.restricted
        @unknown default: throw CameraFailure.unavailable
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .photo
                        self.session.automaticallyConfiguresApplicationAudioSession = false
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraFailure.unavailable }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { throw CameraFailure.unavailable }
                        self.session.addInput(input)
                        self.session.addOutput(self.output)
                        self.configured = true
                    }
                    self.session.startRunning()
                    guard self.session.isRunning, !self.session.isInterrupted else { throw CameraFailure.interrupted }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() {
        queue.async {
            self.session.stopRunning()
            self.pending?.resume(throwing: CancellationError())
            self.pending = nil
            self.pendingID = nil
            self.pendingPhotoID = nil
        }
    }
    func capture() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning, self.pending == nil else { continuation.resume(throwing: CameraFailure.capture); return }
                self.pending = continuation
                let id = UUID()
                self.pendingID = id
                self.queue.asyncAfter(deadline: .now() + 12) {
                    guard self.pendingID == id else { return }
                    self.pending?.resume(throwing: CameraFailure.capture)
                    self.pending = nil
                    self.pendingID = nil
                    self.pendingPhotoID = nil
                }
                if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                let settings = AVCapturePhotoSettings()
                self.pendingPhotoID = settings.uniqueID
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        let photoID = photo.resolvedSettings.uniqueID
        queue.async {
            guard self.pendingPhotoID == photoID else { return }
            let continuation = self.pending
            self.pending = nil
            self.pendingID = nil
            self.pendingPhotoID = nil
            if let image, error == nil { continuation?.resume(returning: image) }
            else { continuation?.resume(throwing: error ?? CameraFailure.capture) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        queue.async {
            guard self.pendingPhotoID == resolvedSettings.uniqueID else { return }
            self.pending?.resume(throwing: error)
            self.pending = nil
            self.pendingID = nil
            self.pendingPhotoID = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

@MainActor enum PhotoSaver {
    static func save(_ image: UIImage) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else {
            throw CameraFailure.photosDenied
        }
        guard let data = image.jpegData(compressionQuality: 0.95) else { throw CameraFailure.capture }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}

@MainActor enum CameraFeedback {
    static func shutter(sound: Bool) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if sound { CameraAudio.shared.play(.shutter) }
    }
    static func finished(sound: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if sound { CameraAudio.shared.play(.finished) }
    }
}


/// App-owned, original PCM samples; no private/system sound identifiers.
enum CameraCue: String, CaseIterable {
    case shutter = "shutter"
    case finished = "print-finished"
    func url(in bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: rawValue, withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

@MainActor
final class CameraAudio: NSObject, AVAudioPlayerDelegate {
    static let shared = CameraAudio()
    private var players: [CameraCue: AVAudioPlayer] = [:]
    private let logger = Logger(subsystem: "studio.wee.Develop", category: "Sound")
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.players.removeAll() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stop(deactivate: false) }
        })
    }

    func play(_ cue: CameraCue) {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audio.setActive(true)
            let player: AVAudioPlayer
            if let existing = players[cue] { player = existing }
            else {
                player = try AVAudioPlayer(contentsOf: cue.url())
                player.delegate = self
                player.volume = 0.85
                player.prepareToPlay()
                players[cue] = player
            }
            player.currentTime = 0
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
        } catch {
            logger.error("Unable to play camera cue: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    /// Muting/backgrounding stops a cue immediately and releases the audio session.
    func stop(deactivate: Bool = true) {
        players.values.forEach { $0.stop() }
        if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.players.values.contains(where: \.isPlaying) else { return }
            self.stop()
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
