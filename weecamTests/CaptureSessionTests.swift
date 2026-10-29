import XCTest
import AVFoundation
@testable import weecam

final class FakeCamera: CameraProviding, @unchecked Sendable {
    let session = AVCaptureSession()
    var startError: Error?
    var captureError: Error?
    var startDelay = 0.0
    var starts = 0
    var stops = 0
    var captures = 0
    func start() async throws {
        starts += 1
        if startDelay > 0 { try await Task.sleep(for: .seconds(startDelay)) }
        if let startError { throw startError }
    }
    func stop() { stops += 1 }
    func capture() async throws -> UIImage {
        captures += 1
        if let captureError { throw captureError }
        return Self.photo()
    }
    static func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 60, width: 80, height: 60))
        }
    }
}

actor FakeRenderer: FilmRendering {
    var fails = false
    func setFailure() { fails = true }
    func render(_ photo: UIImage, progress: Double) -> UIImage? { fails ? nil : photo }
}

@MainActor
final class CaptureSessionTests: XCTestCase {
    let quick = CaptureTiming(flash: 0.01, printTravel: 0.02, development: 0.15, frameInterval: 0.01)
    func makeSession(camera: FakeCamera = FakeCamera(), renderer: any FilmRendering = FakeRenderer(), save: @escaping (UIImage) async throws -> Void = { _ in }) -> CaptureSession {
        CaptureSession(camera: camera, renderer: renderer, timing: quick, feedback: false, saveImage: save)
    }
    func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for state", file: file, line: line)
    }
    func testSequenceBusyGuardAndRepeat() async throws {
        let camera = FakeCamera()
        let model = makeSession(camera: camera)
        await model.setLive(true)
        model.capture(sample: FakeCamera.photo(), reduceMotion: false)
        XCTAssertEqual(model.phase, .capturing)
        XCTAssertFalse(model.canCapture)
        model.capture(sample: FakeCamera.photo(), reduceMotion: false)
        try await wait { model.phase == .printing }
        try await wait { model.phase == .developing }
        try await wait { model.phase == .finished }
        XCTAssertEqual(camera.captures, 1)
        XCTAssertEqual(model.progress, 1)
        XCTAssertFalse(model.isSample)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        XCTAssertFalse(model.flash)
        try await wait { model.phase == .finished }
        XCTAssertEqual(camera.captures, 2)
        model.cancel()
    }
    func testDeniedCameraOffersSettingsAndSampleStillWorks() async throws {
        let camera = FakeCamera(); camera.startError = CameraFailure.denied
        let model = makeSession(camera: camera)
        await model.setLive(true)
        XCTAssertFalse(model.live)
        XCTAssertTrue(model.offerSettings)
        XCTAssertTrue(model.canCapture)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        XCTAssertTrue(model.isSample)
        model.cancel()
    }
    func testUnavailableCameraDoesNotOfferSettings() async {
        let camera = FakeCamera(); camera.startError = CameraFailure.unavailable
        let model = makeSession(camera: camera)
        await model.setLive(true)
        XCTAssertFalse(model.offerSettings)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.canCapture)
    }
    func testFinishedPrintSurvivesBackgroundAndCameraRestarts() async throws {
        let camera = FakeCamera(); let model = makeSession(camera: camera)
        await model.setLive(true)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        let image = model.image
        model.suspend()
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(model.image === image)
        XCTAssertFalse(model.canCapture)
        await model.resume()
        XCTAssertTrue(model.canCapture)
        XCTAssertEqual(camera.starts, 2)
        model.cancel()
    }
    func testDevelopmentPausesInBackground() async throws {
        let model = makeSession()
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .developing }
        model.suspend()
        let progress = model.progress
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.phase, .developing)
        XCTAssertLessThan(model.progress - progress, 0.15)
        await model.resume()
        try await wait { model.phase == .finished }
        model.cancel()
    }
    func testInterruptedCameraCanSwitchToSample() async {
        let model = makeSession()
        await model.setLive(true)
        model.cameraInterrupted()
        XCTAssertFalse(model.canCapture)
        XCTAssertTrue(model.canChangeSource)
        XCTAssertNotNil(model.cameraNotice)
        await model.setLive(false)
        XCTAssertTrue(model.canCapture)
        XCTAssertNil(model.cameraNotice)
    }
    func testCancelledConfigurationDoesNotActivateCamera() async throws {
        let camera = FakeCamera(); camera.startDelay = 0.08
        let model = makeSession(camera: camera)
        let task = Task { await model.setLive(true) }
        try await Task.sleep(for: .milliseconds(20))
        model.suspend()
        await task.value
        XCTAssertFalse(model.live)
        XCTAssertFalse(model.configuring)
        XCTAssertFalse(model.cameraReady)
    }
    func testRenderingFailureRestoresReady() async throws {
        let renderer = FakeRenderer(); await renderer.setFailure()
        let model = makeSession(renderer: renderer)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .ready }
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.printVisible)
        XCTAssertTrue(model.canCapture)
    }
    func testDeniedSavePreservesPrintAndOffersSettings() async throws {
        let model = makeSession(save: { _ in throw CameraFailure.photosDenied })
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        let image = try XCTUnwrap(model.image)
        await model.save(image)
        XCTAssertEqual(model.phase, .finished)
        XCTAssertTrue(model.offerSettings)
        XCTAssertFalse(model.saving)
        XCTAssertTrue(model.image === image)
        model.cancel()
    }
    func testSuccessfulSampleSaveClearsEarlierPermissionRecovery() async throws {
        let camera = FakeCamera(); camera.startError = CameraFailure.denied
        let model = makeSession(camera: camera)
        await model.setLive(true)
        XCTAssertTrue(model.offerSettings)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        await model.save(try XCTUnwrap(model.image))
        XCTAssertEqual(model.message, "Print saved to Photos.")
        XCTAssertFalse(model.offerSettings)
        model.cancel()
    }
    func testBundledSoundCuesDecodeAndHaveAudiblePCM() throws {
        for cue in CameraCue.allCases {
            let url = try cue.url()
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertEqual(player.numberOfChannels, 1)
            XCTAssertGreaterThan(player.duration, 0.1)
            XCTAssertLessThan(player.duration, 0.8)
            let audio = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.1)
            XCTAssertLessThanOrEqual(peak, 1)
        }
    }
    func testTapToRevealFinishesAndNextCaptureDevelopsNormally() async throws {
        let model = CaptureSession(camera: FakeCamera(), renderer: FakeRenderer(),
            timing: CaptureTiming(flash: 0.01, printTravel: 0.02, development: 2, frameInterval: 0.01), feedback: false)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .developing }
        model.revealNow()
        try await wait { model.phase == .finished }
        XCTAssertEqual(model.progress, 1)
        XCTAssertNotNil(model.image)
        XCTAssertTrue(model.canCapture)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .developing }
        XCTAssertLessThan(model.progress, 1)
        model.cancel()
    }
    func testRevealOnlyAppliesDuringActiveDevelopment() async throws {
        let model = makeSession()
        model.revealNow()
        XCTAssertEqual(model.phase, .ready)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        model.revealNow()
        try await wait { model.phase == .developing }
        XCTAssertLessThan(model.progress, 1)
        model.suspend()
        model.revealNow()
        await model.resume()
        try await wait { model.phase == .finished }
        model.cancel()
    }
    func testTakeAnotherKeepsLiveCameraReady() async throws {
        let camera = FakeCamera()
        let model = makeSession(camera: camera)
        await model.setLive(true)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        model.newMoment()
        XCTAssertEqual(model.phase, .capturing)
        try await wait { model.phase == .finished }
        model.newMoment()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.live)
        XCTAssertTrue(model.cameraReady)
        XCTAssertTrue(model.canCapture)
        XCTAssertNil(model.image)
        XCTAssertEqual(camera.starts, 1)
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        XCTAssertEqual(camera.captures, 2)
        model.cancel()
    }
    func testSavedPrintPreventsDuplicateSaveAndNewMomentClearsSavedState() async throws {
        var saves = 0
        let model = makeSession(save: { _ in saves += 1 })
        model.capture(sample: FakeCamera.photo(), reduceMotion: true)
        try await wait { model.phase == .finished }
        let image = try XCTUnwrap(model.image)
        await model.save(image)
        await model.save(image)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(model.hasSaved)
        model.newMoment()
        XCTAssertFalse(model.hasSaved)
        XCTAssertEqual(model.phase, .ready)
    }
    func testCancelPreventsLateUpdates() async throws {
        let model = makeSession()
        model.capture(sample: FakeCamera.photo(), reduceMotion: false)
        model.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertNil(model.image)
        XCTAssertFalse(model.flash)
        XCTAssertFalse(model.printVisible)
    }
    func testRendererRespectsOrientationAndProducesFiniteCrop() async throws {
        let photo = FakeCamera.photo()
        let rotated = UIImage(cgImage: try XCTUnwrap(photo.cgImage), scale: 1, orientation: .right)
        let renderer = FilmRenderer()
        let rendered = await renderer.render(rotated, progress: 1)
        let result = try XCTUnwrap(rendered)
        XCTAssertEqual(result.size.width, 824, accuracy: 1)
        XCTAssertEqual(result.size.height, 768, accuracy: 1)
        XCTAssertEqual(result.imageOrientation, .up)
        // A 90-degree rotation turns the two horizontal color bands into vertical bands.
        let cg = try XCTUnwrap(result.cgImage)
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        let bpp = cg.bitsPerPixel / 8
        let row = (cg.height / 2) * cg.bytesPerRow
        let left = row + (cg.width / 4) * bpp
        let right = row + (cg.width * 3 / 4) * bpp
        let difference = (0..<min(3, bpp)).reduce(0) { $0 + abs(Int(data[left + $1]) - Int(data[right + $1])) }
        XCTAssertGreaterThan(difference, 100)
    }
}
