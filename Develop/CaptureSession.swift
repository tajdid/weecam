import SwiftUI

/// Phase boundaries are kept independent of view geometry and future image processing.
enum CapturePhase: String {
    case ready, capturing, printing, developing, finished
    var caption: String {
        switch self {
        case .ready: "A little moment, made tangible."
        case .capturing: "Hold that thought…"
        case .printing: "Something good is on its way."
        case .developing: "Give it a little time."
        case .finished: "One moment. Yours to keep."
        }
    }
}

/// Injectable timings keep lifecycle tests fast without changing the shipping experience.
struct CaptureTiming: Sendable {
    var flash: Double = 0.18
    var printTravel: Double = 1.45
    var development: Double = 7
    var frameInterval: Double = 1 / 24
}

/// UI state is main-actor isolated; hardware and rendering own their worker executors.
@MainActor @Observable
final class CaptureSession {
    private(set) var phase: CapturePhase = .ready
    private(set) var printVisible = false
    private(set) var flash = false
    private(set) var progress = 0.0
    private(set) var image: UIImage?
    private(set) var isSample = true
    private(set) var live = false
    private(set) var cameraReady = false
    private(set) var configuring = false
    private(set) var saving = false
    private(set) var hasSaved = false
    private(set) var isActive = true
    private(set) var cameraNotice: String?
    var message: String?
    var offerSettings = false
    var sound: Bool {
        didSet {
            UserDefaults.standard.set(sound, forKey: "weecam.sound")
            if !sound && feedback { CameraAudio.shared.stop() }
        }
    }
    let camera: any CameraProviding
    private let renderer: any FilmRendering
    private let saveImage: (UIImage) async throws -> Void
    private let timing: CaptureTiming
    private let feedback: Bool
    private var sequence: Task<Void, Never>?
    private var finishRequested = false
    private var generation = UUID()
    private var sourceGeneration = UUID()
    var canChangeSource: Bool { isActive && (phase == .ready || phase == .finished) && !configuring && !saving }
    var canCapture: Bool { canChangeSource && (!live || cameraReady) }

    init(camera: any CameraProviding = CameraService(), renderer: any FilmRendering = FilmRenderer(),
         timing: CaptureTiming = CaptureTiming(), feedback: Bool = true,
         saveImage: @escaping (UIImage) async throws -> Void = PhotoSaver.save) {
        self.camera = camera
        self.renderer = renderer
        self.timing = timing
        self.feedback = feedback
        self.saveImage = saveImage
        self.sound = UserDefaults.standard.object(forKey: "weecam.sound") as? Bool ?? true
    }

    func setLive(_ enabled: Bool) async {
        guard canChangeSource else { return }
        if !enabled {
            sourceGeneration = UUID()
            camera.stop()
            live = false
            cameraReady = false
            cameraNotice = nil
            return
        }
        await startCamera()
    }

    private func startCamera() async {
        guard isActive, !configuring else { return }
        configuring = true
        let token = UUID()
        sourceGeneration = token
        defer { if sourceGeneration == token { configuring = false } }
        do {
            try await camera.start()
            guard isActive, sourceGeneration == token else { return }
            live = true
            cameraReady = true
            cameraNotice = nil
        } catch {
            guard isActive, sourceGeneration == token else { return }
            cameraReady = false
            if live { cameraNotice = error.localizedDescription }
            present(error)
        }
    }

    func retryCamera() async { await startCamera() }

    /// Stop hardware without discarding an already exposed or finished print.
    func suspend() {
        if feedback { CameraAudio.shared.stop() }
        isActive = false
        sourceGeneration = UUID()
        configuring = false
        cameraReady = false
        camera.stop()
        flash = false
        if phase == .capturing { resetCapture() }
    }

    func resume() async {
        isActive = true
        if live { await startCamera() }
    }

    func cameraInterrupted() {
        guard live else { return }
        cameraReady = false
        cameraNotice = "Camera paused. Try again or use the sample."
        camera.stop()
        if phase == .capturing { resetCapture() }
    }

    func cameraRecovered() async {
        guard live, isActive else { return }
        await startCamera()
    }

    func capture(sample: UIImage, reduceMotion: Bool) {
        guard canCapture else { return }
        sequence?.cancel()
        let token = UUID()
        generation = token
        printVisible = false
        progress = 0
        image = nil
        hasSaved = false
        message = nil
        offerSettings = false
        isSample = !live
        phase = .capturing
        finishRequested = false
        flash = !reduceMotion
        Task { [weak self, timing] in
            try? await Task.sleep(for: .seconds(timing.flash))
            if self?.generation == token { self?.flash = false }
        }
        if feedback { CameraFeedback.shutter(sound: sound) }
        sequence = Task { [weak self] in
            guard let self else { return }
            do {
                let source = self.live ? try await self.camera.capture() : sample
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard let initial = await self.renderer.render(source, progress: 0) else { throw CameraFailure.rendering }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.image = initial
                try await Task.sleep(for: .seconds(self.timing.flash))
                try await self.waitUntilActive()
                self.phase = .printing
                withAnimation(reduceMotion ? .linear(duration: 0.2) : .spring(response: 1.15, dampingFraction: 0.82)) { self.printVisible = true }
                try await Task.sleep(for: .seconds(self.timing.printTravel))
                try await self.waitUntilActive()
                self.phase = .developing
                var elapsed = 0.0
                var lastFrame = ContinuousClock.now
                repeat {
                    try Task.checkCancellation()
                    if !self.isActive {
                        try await self.waitUntilActive()
                        lastFrame = .now
                    }
                    let now = ContinuousClock.now
                    let duration = lastFrame.duration(to: now)
                    elapsed += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                    lastFrame = now
                    let p = self.finishRequested ? 1 : min(1, elapsed / self.timing.development)
                    guard let frame = await self.renderer.render(source, progress: p) else { throw CameraFailure.rendering }
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.image = frame
                    self.progress = p
                    if p >= 1 { break }
                    try await Task.sleep(for: .seconds(self.timing.frameInterval))
                } while true
                self.phase = .finished
                if self.feedback && self.isActive { CameraFeedback.finished(sound: self.sound) }
            } catch is CancellationError {
                if self.generation == token { self.resetCapture() }
            } catch {
                guard self.generation == token else { return }
                self.resetCapture()
                self.present(error)
            }
        }
    }

    /// Fast-forward the existing pipeline; its final render still owns the finished image.
    func revealNow() {
        guard phase == .developing, isActive else { return }
        finishRequested = true
    }

    private func waitUntilActive() async throws {
        while !isActive { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
    }

    func save(_ printImage: UIImage) async {
        guard phase == .finished, !saving, !hasSaved else { return }
        saving = true
        defer { saving = false }
        do { try await saveImage(printImage); hasSaved = true; offerSettings = false; message = "Print saved to Photos." }
        catch { present(error) }
    }

    /// Return to framing while preserving the chosen camera and its running session.
    func newMoment() {
        guard phase == .finished, !saving else { return }
        resetCapture()
        message = nil
        offerSettings = false
    }

    private func present(_ error: Error) {
        offerSettings = (error as? CameraFailure) == .denied || (error as? CameraFailure) == .photosDenied
        message = error.localizedDescription
    }

    private func resetCapture() {
        generation = UUID()
        sequence?.cancel()
        sequence = nil
        phase = .ready
        printVisible = false
        progress = 0
        finishRequested = false
        flash = false
        image = nil
        hasSaved = false
    }

    func cancel() {
        if feedback { CameraAudio.shared.stop() }
        sourceGeneration = UUID()
        configuring = false
        camera.stop()
        live = false
        cameraReady = false
        cameraNotice = nil
        resetCapture()
    }
}
