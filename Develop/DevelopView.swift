import SwiftUI
import AVFoundation
import LinkPresentation

private enum Ink {
    static let paper = Color(red: 243/255, green: 240/255, blue: 233/255)
    static let ivory = Color(red: 1, green: 248/255, blue: 234/255)
    static let coral = Color(red: 243/255, green: 107/255, blue: 63/255)
    static let charcoal = Color(red: 36/255, green: 36/255, blue: 36/255)
}

struct DevelopView: View {
    @State private var session = CaptureSession()
    @State private var printDrag = CGSize.zero
    @State private var printAngle = -3.0
    @State private var holdingPrint = false
    @State private var darkroomArrived = false
    @GestureState private var dragTranslation = CGSize.zero
    @GestureState private var rotation = Angle.zero
    @State private var sharedPrint: SharedPrint?
    @Namespace private var printSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Moment { case camera, darkroom, print }
    private var moment: Moment {
        switch session.phase {
        case .ready, .capturing, .printing: .camera
        case .developing: .darkroom
        case .finished: .print
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (moment == .darkroom ? Ink.charcoal : Ink.paper).ignoresSafeArea()
                switch moment {
                case .camera: cameraScene(geometry.size).transition(.opacity)
                case .darkroom: darkroomScene(geometry.size).transition(.opacity)
                case .print: finishedScene(geometry.size).transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.6), value: moment)
        }
        .foregroundStyle(Ink.charcoal)
        .task(id: moment) {
            darkroomArrived = false
            guard moment == .darkroom else { return }
            if reduceMotion { darkroomArrived = true; return }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.85, dampingFraction: 0.8)) { darkroomArrived = true }
        }
        .preferredColorScheme(moment == .darkroom ? .dark : .light)
        .sheet(item: $sharedPrint) { item in PrintShareSheet(image: item.image).presentationDetents([.medium, .large]) }
        .onDisappear { session.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.suspend() }
            if phase == .active { Task { await session.resume() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: session.camera.session).receive(on: RunLoop.main)) { _ in session.cameraInterrupted() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: session.camera.session).receive(on: RunLoop.main)) { _ in
            Task { await session.cameraRecovered() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session.camera.session).receive(on: RunLoop.main)) { notification in
            session.cameraInterrupted()
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError, error.code == .mediaServicesWereReset {
                Task { await session.cameraRecovered() }
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .capturing || phase == .ready { printDrag = .zero; printAngle = -3 }
        }
        .alert("weecam", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            if session.offerSettings {
                Button("Open Settings") {
                    session.message = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("OK", role: .cancel) { session.message = nil }
        } message: { Text(session.message ?? "") }
    }

    private func cameraScene(_ size: CGSize) -> some View {
        let scale = min(1.1, (size.width - 40) / 350, (size.height - 160) / 570)
        return VStack(spacing: 0) {
            HStack(alignment: .center) {
                Button {
                    Task { await session.setLive(!session.live) }
                } label: {
                    Label(session.configuring ? "Opening…" : (session.live ? "Use sample" : "Use camera"),
                          systemImage: session.live ? "photo" : "camera")
                        .font(.system(size: 16, weight: .regular))
                        .frame(minHeight: 44)
                }.disabled(!session.canChangeSource)
                Spacer()
                Button { session.sound.toggle() } label: {
                    Image(systemName: session.sound ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 18, weight: .light)).frame(width: 44, height: 44)
                }.accessibilityLabel(session.sound ? "Mute sound" : "Enable sound")
            }.padding(.horizontal, 26).padding(.top, 12)
            Spacer(minLength: 8)
            ZStack(alignment: .top) {
                if session.printVisible {
                    InstantPrint(image: session.image, progress: session.progress, isSample: session.isSample)
                        .matchedGeometryEffect(id: "moment-print", in: printSpace)
                        .rotationEffect(.degrees(-3), anchor: .top)
                        .offset(y: session.printVisible ? 282 : 0)
                        .transition(.offset(y: -260))
                        .accessibilityHidden(true)
                }
                CameraBody(camera: session.camera, live: session.live, isCapturing: session.flash, enabled: session.canCapture, shutter: capture)
                    .zIndex(1)
                if session.phase == .ready {
                    MomentTagline().offset(y: 380)
                }
            }
            .frame(width: 350, height: 550, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .frame(height: 550 * scale)
            Spacer(minLength: 8)
            if let notice = session.cameraNotice {
                HStack {
                    Text(notice).font(.caption)
                    Button("Retry") { Task { await session.retryCamera() } }.disabled(session.configuring)
                }.padding(.horizontal, 26)
            }
            Text(session.phase == .ready ? "Press the coral shutter." : "Making your print…")
                .font(.subheadline).foregroundStyle(Ink.charcoal.opacity(0.6))
                .frame(minHeight: 44).padding(.horizontal, 26).padding(.bottom, 12)
        }.tint(Ink.charcoal)
    }

    private func darkroomScene(_ size: CGSize) -> some View {
        let width = min(310, size.width - 84, (size.height - 235) / 1.18)
        return VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(spacing: 10) {
                Text("Developing").font(.system(size: 30, design: .serif))
                Text("Good things take a moment.").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 28)
            printFace(width: width)
                .rotationEffect(.degrees(reduceMotion ? 0 : (darkroomArrived ? -2 : -16)))
                .scaleEffect(reduceMotion || darkroomArrived ? 1 : 0.92)
                .offset(y: reduceMotion || darkroomArrived ? 0 : 26)
                .opacity(reduceMotion || darkroomArrived ? 1 : 0)
                .onTapGesture { session.revealNow() }
                .accessibilityHint("Tap to finish developing")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { session.revealNow() }
            Spacer(minLength: 28)
            VStack(spacing: 20) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(Ink.coral).frame(width: max(4, g.size.width * session.progress))
                    }
                }.frame(width: 160, height: 3)
                    .accessibilityLabel("Development progress")
                    .accessibilityValue("\(Int(session.progress * 100)) percent")
                Button("Tap print to reveal") { session.revealNow() }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65)).frame(minHeight: 44)
            }
            Spacer(minLength: 16)
        }.foregroundStyle(.white).frame(maxWidth: .infinity)
    }

    private func finishedScene(_ size: CGSize) -> some View {
        let width = min(320, size.width - 84, (size.height - 235) / 1.18)
        return VStack(spacing: 0) {
            HStack {
                Button(action: session.newMoment) {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                }.accessibilityLabel("Back to camera")
                    .disabled(session.saving)
                Spacer()
                Text("Your moment.").font(.system(size: 24, design: .serif))
                Spacer()
                Button(action: sharePrint) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }.accessibilityLabel("Share print").disabled(session.saving)
            }.font(.system(size: 18, weight: .light)).padding(.horizontal, 16).padding(.top, 8)
            Spacer(minLength: 22)
            interactivePrint(width: width)
            Spacer(minLength: 22)
            VStack(spacing: 4) {
                Button(action: savePrint) {
                    HStack(spacing: 9) {
                        if session.hasSaved { Image(systemName: "checkmark") }
                        Text(session.saving ? "Saving…" : (session.hasSaved ? "Saved to Photos" : "Save print"))
                    }.font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 54)
                        .background(Ink.charcoal, in: Capsule()).foregroundStyle(Ink.ivory)
                }.disabled(session.saving || session.hasSaved)
                Button("Take another", action: session.newMoment)
                    .font(.subheadline).frame(minHeight: 44).disabled(session.saving)
            }.frame(maxWidth: 320).padding(.horizontal, 30).padding(.bottom, 16)
        }.frame(maxWidth: .infinity).tint(Ink.charcoal)
    }

    private func printFace(width: CGFloat) -> some View {
        InstantPrint(image: session.image, progress: session.progress, isSample: session.isSample, showsShadow: moment != .darkroom)
            .scaleEffect(width / 230)
            .frame(width: width, height: width * 1.18)
            .matchedGeometryEffect(id: "moment-print", in: printSpace)
    }

    private func interactivePrint(width: CGFloat) -> some View {
        printFace(width: width)
            .rotationEffect(.degrees(printAngle) + rotation)
            .offset(boundedOffset(CGSize(width: printDrag.width + dragTranslation.width, height: printDrag.height + dragTranslation.height)))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : max(-7, min(7, Double(dragTranslation.width / 18)))), axis: (x: 0, y: 1, z: 0))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : max(-7, min(7, Double(-dragTranslation.height / 18)))), axis: (x: 1, y: 0, z: 0))
            .scaleEffect(!reduceMotion && holdingPrint ? 1.025 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75), value: holdingPrint)
            .gesture(DragGesture(minimumDistance: 5).updating($dragTranslation) { value, state, _ in
                state = value.translation
            }.onChanged { _ in pickUpPrint() }.onEnded { value in
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75)) {
                    printDrag = boundedOffset(CGSize(width: printDrag.width + value.translation.width, height: printDrag.height + value.translation.height))
                    holdingPrint = false
                }
            })
            .simultaneousGesture(RotationGesture().updating($rotation) { angle, state, _ in
                state = Angle(degrees: max(-18, min(18, angle.degrees)))
            }.onChanged { _ in pickUpPrint() }.onEnded { angle in
                printAngle = max(-18, min(18, printAngle + angle.degrees))
                holdingPrint = false
            })
            .onTapGesture(count: 2, perform: resetPrint)
            .contextMenu {
                Button("Save print", systemImage: "square.and.arrow.down", action: savePrint).disabled(session.hasSaved || session.saving)
                Button("Share print", systemImage: "square.and.arrow.up", action: sharePrint)
                Button("Reset position", systemImage: "arrow.counterclockwise", action: resetPrint)
            }
            .accessibilityHint("Drag to move and tilt. Rotate with two fingers. Double tap to reset. Hold for actions.")
            .accessibilityActions {
                Button("Save print", action: savePrint)
                Button("Share print", action: sharePrint)
                Button("Reset position", action: resetPrint)
            }
    }

    private func capture() {
        let renderer = ImageRenderer(content: SampleScene().frame(width: 206, height: 192))
        renderer.scale = 4
        if let sample = renderer.uiImage { session.capture(sample: sample, reduceMotion: reduceMotion) }
    }
    private func pickUpPrint() {
        if !holdingPrint { UIImpactFeedbackGenerator(style: .light).impactOccurred(); holdingPrint = true }
    }
    private func boundedOffset(_ offset: CGSize) -> CGSize {
        CGSize(width: max(-32, min(32, offset.width)), height: max(-26, min(26, offset.height)))
    }
    private func resetPrint() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7)) { printDrag = .zero; printAngle = -3 }
    }
    private func renderedPrint() -> UIImage? {
        guard session.phase == .finished else { return nil }
        let renderer = ImageRenderer(content: InstantPrint(image: session.image, progress: 1, isSample: session.isSample, showsShadow: false))
        renderer.scale = 4
        return renderer.uiImage
    }
    private func savePrint() {
        guard !session.saving, !session.hasSaved, let image = renderedPrint() else { return }
        Task { await session.save(image) }
    }
    private func sharePrint() {
        guard let image = renderedPrint() else { return }
        sharedPrint = SharedPrint(image: image)
    }
}

/// Replays on return to the camera; reduced motion presents the complete text immediately.
private struct MomentTagline: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 3) {
            Text("A little moment,")
                .opacity(reduceMotion || appeared ? 1 : 0)
                .offset(y: reduceMotion || appeared ? 0 : 9)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: appeared)
            Text("made tangible.")
                .opacity(reduceMotion || appeared ? 1 : 0)
                .offset(y: reduceMotion || appeared ? 0 : 9)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.65).delay(0.18), value: appeared)
        }
        .font(.system(size: 25, design: .serif)).italic().multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A little moment, made tangible.")
        .task {
            guard !reduceMotion else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            appeared = true
        }
    }
}

private struct SharedPrint: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PrintShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [PrintShareItem(image: image)], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class PrintShareItem: NSObject, UIActivityItemSource {
    let image: UIImage
    init(image: UIImage) { self.image = image }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = "A moment, made tangible."
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

private struct PrintActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: 44).contentShape(Rectangle()).opacity(configuration.isPressed ? 0.5 : 1)
    }
}

private struct CameraBody: View {
    let camera: any CameraProviding
    let live: Bool
    let isCapturing: Bool
    let enabled: Bool
    let shutter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("weecam.").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
                RoundedRectangle(cornerRadius: 5).fill(Ink.charcoal).frame(width: 48, height: 27)
                    .overlay {
                        if live { CameraPreview(session: camera.session).clipShape(RoundedRectangle(cornerRadius: 3)).padding(3) }
                        else { RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.18)).padding(5) }
                    }
                RoundedRectangle(cornerRadius: 4).fill(isCapturing ? .white : Color(red: 0.77, green: 0.75, blue: 0.69))
                    .frame(width: 35, height: 24)
                    .overlay { HStack(spacing: 3) { ForEach(0..<5) { _ in Rectangle().fill(.white.opacity(0.45)).frame(width: 1) } }.padding(4) }
                    .shadow(color: .white.opacity(isCapturing ? 1 : 0), radius: 35)
            }.padding(.horizontal, 25).padding(.top, 24)
            HStack(spacing: 24) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color.white, Color.gray.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 151, height: 151)
                    Circle().fill(Ink.charcoal).frame(width: 137, height: 137)
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 1).frame(width: 121, height: 121)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 105, height: 105)
                    Circle().fill(Color(red: 0.12, green: 0.21, blue: 0.24)).frame(width: 72, height: 72)
                    Circle().fill(Color(white: 0.055)).frame(width: 48, height: 48)
                    Group {
                        if live { CameraPreview(session: camera.session).frame(width: 96, height: 96).clipShape(Circle()) }
                    }
                    Ellipse().fill(.white.opacity(0.25)).frame(width: 24, height: 12).rotationEffect(.degrees(-40)).offset(x: -15, y: -20)
                    Text("WEE OPTICS • 38mm").font(.system(size: 7, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).offset(y: 59)
                }.shadow(color: .black.opacity(0.18), radius: 5, y: 5)
                VStack(spacing: 12) {
                    Button(action: shutter) {
                        Circle().fill(LinearGradient(colors: [Ink.coral, Color(red: 0.83, green: 0.27, blue: 0.14)], startPoint: .top, endPoint: .bottom))
                            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1).padding(3))
                            .padding(6).background(Circle().fill(Color(red: 0.86, green: 0.82, blue: 0.74)))
                            .shadow(color: Ink.coral.opacity(0.22), radius: 6, y: 5)
                    }.frame(width: 72, height: 72).buttonStyle(ShutterStyle()).disabled(!enabled)
                        .accessibilityLabel("Shutter").accessibilityHint(live ? "Capture a photograph and make an instant print" : "Print an illustrated sample photograph")
                    Text("PRESS TO\nREMEMBER").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(1.2).multilineTextAlignment(.center).lineSpacing(3).fixedSize()
                }
            }.padding(.top, 18)
            Spacer(minLength: 14)
            HStack(spacing: 4) {
                ForEach(0..<3) { index in Rectangle().fill([Ink.coral, Color(red: 0.89, green: 0.66, blue: 0.32), Color(red: 0.45, green: 0.56, blue: 0.49)][index]).frame(width: 6) }
                Spacer()
                Text("INSTANT CAMERA").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2)
            }.frame(height: 15).padding(.horizontal, 27).padding(.bottom, 18)
            Capsule().fill(Ink.charcoal).frame(height: 11).overlay(Capsule().fill(.black).padding(3)).padding(.horizontal, 31).padding(.bottom, 15)
        }
        .frame(width: 330, height: 300)
        .background(LinearGradient(colors: [Ink.ivory, Color(red: 0.92, green: 0.88, blue: 0.79)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 34))
        .overlay(RoundedRectangle(cornerRadius: 34).strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
        .shadow(color: Ink.charcoal.opacity(0.12), radius: 18, x: 0, y: 16)
        .overlay { if isCapturing { RoundedRectangle(cornerRadius: 34).fill(.white.opacity(0.65)).allowsHitTesting(false) } }
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct InstantPrint: View {
    let image: UIImage?
    let progress: Double
    let isSample: Bool
    var showsShadow = true
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.81, green: 0.79, blue: 0.71)
                if let image { Image(uiImage: image).resizable().scaledToFill().opacity(0.04 + progress * 0.96) }
            }.frame(width: 206, height: 192).clipped()
            Text("a slower kind of moment").font(.system(size: 12, design: .serif)).italic().padding(.top, 16)
            Text(isSample ? "ILLUSTRATED SAMPLE" : "MADE WITH WEECAM")
                .font(.system(size: 6, design: .monospaced)).tracking(1.4).opacity(0.4).padding(.top, 7)
        }
        .padding(12).padding(.bottom, 8).frame(width: 230)
        .background(PaperStock())
        .foregroundStyle(Ink.charcoal)
        .shadow(color: .black.opacity(showsShadow ? 0.16 : 0), radius: 8, x: 2, y: 8)
        .accessibilityLabel(progress >= 1 ? "Developed instant print" : "Instant print developing")
    }
}

/// A fixed, code-drawn fiber pattern keeps paper texture still during development.
private struct PaperStock: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0.99, blue: 0.95)))
            for index in 0..<650 {
                let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                let y = CGFloat((index * 149 + 37) % 991) / 991 * size.height
                let fiber = CGRect(x: x, y: y, width: index.isMultiple(of: 3) ? 0.8 : 0.35, height: 1.1)
                context.fill(Path(ellipseIn: fiber), with: .color(Ink.charcoal.opacity(0.055)))
            }
        }.accessibilityHidden(true)
    }
}

/// Deliberately illustrated placeholder, bundled as native drawing code; no network or photo access.
private struct SampleScene: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Color(red: 0.57, green: 0.72, blue: 0.74), Color(red: 0.94, green: 0.78, blue: 0.57)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.9, blue: 0.66)).frame(width: 45, height: 45).position(x: 153, y: 49)
                Rectangle().fill(Color(red: 0.29, green: 0.52, blue: 0.57)).frame(height: 90).position(x: g.size.width / 2, y: 147)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 92)); p.addCurve(to: CGPoint(x: 206, y: 183), control1: CGPoint(x: 110, y: 112), control2: CGPoint(x: 54, y: 163)); p.addLine(to: CGPoint(x: 206, y: 210)); p.addLine(to: CGPoint(x: 0, y: 210)); p.closeSubpath()
                }.fill(Color(red: 0.81, green: 0.57, blue: 0.37))
                Path { p in p.move(to: CGPoint(x: 0, y: 119)); p.addQuadCurve(to: CGPoint(x: 175, y: 186), control: CGPoint(x: 110, y: 140)) }.stroke(Color(red: 0.97, green: 0.87, blue: 0.68), lineWidth: 4)
            }
        }
    }
}

#Preview { DevelopView() }
