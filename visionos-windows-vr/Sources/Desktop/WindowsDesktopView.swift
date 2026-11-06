import SwiftUI
import UIKit
import Metal
import Darwin
import Observation
import WindowsVRCore
import GameController

@MainActor
@Observable
final class WindowsDesktopControls {
    weak var surface: WindowsDesktopSurface?
    var inputMessage: String?
    var audioMessage: String?
    var resettingAudio = false
    var gamepadStatus = L("No gamepad connected", "Kein Gamepad verbunden")
    func setActive(_ active: Bool) { surface?.setSceneActive(active) }
    func keyboard() { surface?.toggleKeyboard() }
    func key(_ vk: Int32) {
        WindowsVRAudioDiagnostics.control("desktop control vk=\(vk)") { surface?.pulseKey(vk) }
    }
    func rightClick() { surface?.rightClick() }
    func scroll(_ delta: Int32) { surface?.scroll(delta) }
    func releaseInput() { surface?.releaseInput() }
    func resetAudio() {
        guard !resettingAudio else { return }
        resettingAudio = true
        audioMessage = L("Resetting audio…", "Audio wird zurückgesetzt…")
        Task { @MainActor in
            let success = await WindowsVRAudioDiagnostics.resetOutput(reason: "desktop control")
            audioMessage = success ? L("Audio output restarted. Check whether the sound is clear.", "Audioausgabe neu gestartet. Prüfe, ob der Ton klar ist.") :
                L("Audio could not be reset. Try again.", "Audio konnte nicht zurückgesetzt werden. Erneut versuchen.")
            resettingAudio = false
        }
    }
}

struct WindowsDesktopView: View {
    @Bindable var model: LauncherModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var controls = WindowsDesktopControls()
    @Namespace private var controlsHoverNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var controlsHoverGroup: HoverEffectGroup { HoverEffectGroup(controlsHoverNamespace) }

    var body: some View {
        WindowsDesktopSurfaceView(model: model, controls: controls)
            // Claim the complete SwiftUI game region as well as its Metal
            // UIView, so visionOS exposes a pre-paired pad during setup.
            .handlesGameControllerEvents(matching: .gamepad)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 360)
            .accessibilityLabel(L("Windows app screen", "Windows-App-Anzeige"))
            .ornament(attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
                sessionControls
                    .padding(.trailing, 20)
            }
            .onChange(of: scenePhase) { _, phase in
                WindowsVRAudioDiagnostics.snapshot("desktop scene \(phase)")
                controls.setActive(phase == .active)
                if phase == .active { WindowsVRAudioDiagnostics.requestPlayback() }
                if phase != .active { controls.releaseInput() }
            }
            .onAppear { controls.setActive(scenePhase == .active) }
            .onDisappear {
                WindowsVRAudioDiagnostics.snapshot("desktop disappeared")
                controls.setActive(false)
                controls.releaseInput()
            }
    }

    private var sessionControls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            VStack(spacing: 8) {
                Button { controls.keyboard() } label: {
                    railLabel(L("Keyboard", "Tastatur"), systemImage: "keyboard")
                }
                .disabled(!model.hasAcceptedLaunch)
                Menu {
                    Label(controls.gamepadStatus, systemImage: "gamecontroller")
                    Button("Escape") { controls.key(0x1B) }
                    Button("Tab") { controls.key(0x09) }
                    Button("Enter") { controls.key(0x0D) }
                    Button(L("Right click", "Rechtsklick")) { controls.rightClick() }
                    Button(L("Scroll up", "Nach oben scrollen")) { controls.scroll(120) }
                    Button(L("Scroll down", "Nach unten scrollen")) { controls.scroll(-120) }
                    Button(L("Reset audio", "Audio zurücksetzen")) { controls.resetAudio() }
                        .disabled(controls.resettingAudio || model.isStopping)
                } label: {
                    railLabel(L("Controls", "Steuerung"), systemImage: "cursorarrow")
                }
                .disabled(!model.hasAcceptedLaunch)
                if model.hasAcceptedLaunch {
                    Button(role: .destructive) { Task { await model.stop() } } label: {
                        railLabel(L("End session", "Sitzung beenden"), systemImage: "stop.fill")
                            .foregroundStyle(.red)
                    }.disabled(model.isStopping || model.stopRequested)
                } else {
                    Button { model.hideDesktopPresentation() } label: {
                        railLabel(L("Library", "Bibliothek"), systemImage: "square.grid.2x2")
                    }.disabled(model.isLaunching)
                }
            }
            .buttonStyle(.plain)
            .padding(8)
            .glassBackgroundEffect(in: .rect(cornerRadius: 32))
            // The trailing edge and icons stay still; labels expand away from
            // the game. System hover effects respond to gaze without tracking it.
            .hoverEffect(in: controlsHoverGroup) { effect, active, proxy in
                effect.animation(reduceMotion ? nil : .easeInOut(duration: 0.2).delay(active ? 0.35 : 0.2)) {
                    $0.clipShape(.rect(cornerRadius: 32).size(
                        width: active ? proxy.size.width : 64,
                        height: proxy.size.height, anchor: .trailing))
                }
            }
            if model.isLaunching || !model.hasAcceptedLaunch || model.launchError != nil || model.stopRequested || model.requiresRestart || controls.inputMessage != nil || controls.audioMessage != nil {
                VStack(spacing: 8) {
                    if model.isLaunching || !model.hasAcceptedLaunch || model.launchError != nil || model.stopRequested || model.requiresRestart {
                        HStack(spacing: 8) {
                            if model.isLaunching { ProgressView() }
                            Text(model.launchError ?? model.sessionStatus)
                                .font(.footnote)
                                .foregroundStyle(model.launchError == nil ? Color.secondary : Color.red)
                        }
                    }
                    if model.stopRequested || model.requiresRestart { ForceQuitSessionButton() }
                    if let message = controls.inputMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                    if let message = controls.audioMessage {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(width: 216)
                .glassBackgroundEffect()
            }
        }
    }

    private func railLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hoverEffect(in: controlsHoverGroup) { effect, active, _ in
                    effect.animation(reduceMotion ? nil : .easeInOut(duration: 0.2).delay(active ? 0.35 : 0.2)) {
                        $0.opacity(active ? 1 : 0)
                    }
                }
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
        }
        .frame(width: 200, height: 48)
        .contentShape(.hoverEffect, .capsule)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct WindowsDesktopSurfaceView: UIViewRepresentable {
    let model: LauncherModel
    let controls: WindowsDesktopControls
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> WindowsDesktopSurface {
        let view = WindowsDesktopSurface(controls: controls)
        view.didAttach = { [weak model] in model?.desktopSurfaceDidAttach() }
        view.didDetach = { [weak model] in model?.desktopSurfaceDidDetach() }
        controls.surface = view
        return view
    }

    func updateUIView(_ view: WindowsDesktopSurface, context: Context) {
        // UIKit can attach this view while the StikDebug handoff still leaves
        // its window temporarily inactive. Apply SwiftUI's current phase on
        // every update, including the update accepting the runtime launch.
        view.setSceneActive(scenePhase == .active)
        // A normal Windows app can ask to save after Alt-F4; keep that dialog usable.
        view.inputEnabled = model.hasAcceptedLaunch && !model.isStopping
        view.aspectRatio = model.desktopAspectRatioDraft
        // Runtime launch applies the session's display environment after this
        // view first attaches. Re-read it when launch state changes, too.
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: WindowsDesktopSurface, coordinator: ()) {
        view.stopGamepad()
        view.releaseInput()
        view.restoreWindowGeometry()
        view.didDetach?()
        _ = winios_compositor_set_hidden(1)
    }
}

/// Hosts DXMT and the existing GDI desktop compositor in the same window rect.
@MainActor
final class WindowsDesktopSurface: UIView, UIKeyInput {
    private let metalLayer = CAMetalLayer()
    private let gamepad = WindowsDesktopGamepad()
    private let steamController = SteamControllerBluetooth()
    private let gamepadInteraction = GCEventInteraction()
    private var sceneActive = false
    private var lastGamepadRouting: String?
    private weak var controls: WindowsDesktopControls?
    private var keysHeld: Set<Int32> = []
    private var activeTouch: UITouch?
    private var pointer: (Int32, Int32) = (0, 0)
    private lazy var pointerInput = WindowsDesktopPointerInput(
        frame: { wvr_desktop_pointer_frame_v1() },
        send: { winios_pointer($0, $1, $2, $3) })
    private var attached = false
    private weak var presentationScene: UIWindowScene?
    private var previousWindowSize: CGSize?
    private var previousResizingRestrictions: UIWindowScene.ResizingRestrictions = .freeform
    private var guestAspectRatio: CGFloat?
    var aspectRatio: WindowsDesktopAspectRatio = .automatic {
        didSet {
            guard aspectRatio != oldValue else { return }
            activePresentation = nil
            candidateWindow = 0
            guestAspectRatio = nil
            setNeedsLayout()
        }
    }
    private var presentationTask: Task<Void, Never>?
    private var activePresentation: WVRDesktopPresentationV1?
    private var appliedCompositorFrame: CGRect?
    private var candidateWindow: UInt64 = 0
    private var candidateRatio: Double = 0
    private var candidateSince: TimeInterval = 0
    private var missingSince: TimeInterval?
    private typealias CopyPresentation = @convention(c) (UnsafeMutablePointer<WVRDesktopPresentationV1>?) -> Int32
    // The preserved-runtime build can still show the whole desktop when the
    // optional versioned presentation bridge is unavailable.
    private static let copyPresentation: CopyPresentation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "wvr_desktop_copy_presentation_v1") else { return nil }
        return unsafeBitCast(symbol, to: CopyPresentation.self)
    }()
    var didAttach: (() -> Void)?
    var didDetach: (() -> Void)?
    var inputEnabled = false {
        didSet {
            updateGamepadInput()
            if !inputEnabled { releaseInput() }
        }
    }

    init(controls: WindowsDesktopControls) {
        self.controls = controls
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = true
        addInteraction(gamepadInteraction)
        gamepad.diagnostic = { LaunchLogFile.append("notice", "Gamepad: \($0)") }
        gamepad.inputReceived = { WindowsVRAudioDiagnostics.requestPlayback() }
        steamController.diagnostic = { LaunchLogFile.append("notice", "Gamepad: \($0)") }
        steamController.stateChanged = { [weak gamepad] in gamepad?.setSteamControllerState($0) }
        gamepad.controllersChanged = { [weak controls] names in
            if !WindowsDesktopGamepad.isAvailable {
                controls?.gamepadStatus = L("Gamepad bridge unavailable in this runtime", "Gamepad-Brücke in dieser Laufzeit nicht verfügbar")
            } else {
                controls?.gamepadStatus = names.isEmpty ? L("No gamepad connected", "Kein Gamepad verbunden") : names.joined(separator: ", ")
            }
            LaunchLogFile.append("notice", "Desktop XInput controllers: \(names.joined(separator: ", ")); bridge=\(WindowsDesktopGamepad.isAvailable)")
        }
        layer.addSublayer(metalLayer)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = CGSize(width: 1024, height: 768)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(displayModeChanged),
                                               name: Notification.Name("MadeiraDisplayModeChanged"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopGamepad()
            restoreWindowGeometry()
            releaseInput()
            attached = false
            didDetach?()
        } else {
            // Preserve the phase supplied by SwiftUI. Attachment can precede
            // UIKit's activation transition without another SwiftUI onChange.
            gamepad.start()
            steamController.start()
            updateGamepadInput()
        }
        setNeedsLayout()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        updateGamepadInput()
    }

    private func updateGamepadInput() {
        let enabled = window != nil && sceneActive && inputEnabled && WindowsDesktopGamepad.isAvailable
        let routing = "enabled=\(enabled) window=\(window != nil) sceneActive=\(sceneActive) accepted=\(inputEnabled) bridge=\(WindowsDesktopGamepad.isAvailable)"
        if routing != lastGamepadRouting {
            lastGamepadRouting = routing
            LaunchLogFile.append("notice", "Gamepad routing: \(routing)")
        }
        gamepadInteraction.handledEventTypes = window != nil && sceneActive ? .gamepad : []
        gamepad.setEnabled(enabled)
        steamController.setActive(enabled)
    }

    func stopGamepad() {
        gamepadInteraction.handledEventTypes = []
        steamController.stop()
        gamepad.stop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        updateWindowGeometry()
        if presentationTask == nil {
            presentationTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.samplePresentation()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        metalLayer.frame = bounds
        if !attached {
            guard let device = MTLCreateSystemDefaultDevice(),
                  wvr_compositor_bind_metal_device_v1(Unmanaged.passUnretained(device as AnyObject).toOpaque()) == 0 else {
                controls?.inputMessage = L("Metal could not prepare the desktop screen.", "Metal konnte die Desktop-Anzeige nicht vorbereiten.")
                return
            }
            metalLayer.device = device
            let pointerTiming = wvr_desktop_pointer_timing_install_v1()
            madeira_display_set_layer(metalLayer)
            attached = true
            _ = winios_compositor_set_hidden(0)
            didAttach?()
            LaunchLogFile.append("desktop", "Desktop surface attached; Metal device bound, pointer frame timing=\(pointerTiming)")
        }
        let rect = convert(bounds, to: window)
        winios_set_desktop_rect(0, 0, 0, 0, 0)
        var compositor = rect
        if aspectRatio != .desktop, let sample = activePresentation {
            let current = CGRect(x: sample.compositor_x, y: sample.compositor_y,
                                 width: sample.compositor_width, height: sample.compositor_height)
            let client = CGRect(x: sample.x, y: sample.y, width: sample.view_width, height: sample.view_height)
            compositor = WindowsDesktopPresentation.compositorFrame(current: current, client: client, viewport: rect) ?? rect
        }
        let changed = appliedCompositorFrame.map {
            abs($0.minX - compositor.minX) > 0.25 || abs($0.minY - compositor.minY) > 0.25 ||
            abs($0.width - compositor.width) > 0.25 || abs($0.height - compositor.height) > 0.25
        } ?? true
        if changed {
            appliedCompositorFrame = compositor
            winios_set_compositor_frame(compositor.minX, compositor.minY, compositor.width, compositor.height)
        }
    }

    private func samplePresentation() {
        guard window != nil, aspectRatio != .desktop else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var sample = WVRDesktopPresentationV1()
        if Self.copyPresentation?(&sample) == 1, sample.width > 0, sample.height > 0 {
            missingSince = nil
            let ratio = sample.width / sample.height
            if sample.window != candidateWindow || abs(ratio - candidateRatio) > 0.002 {
                candidateWindow = sample.window
                candidateRatio = ratio
                candidateSince = now
            }
            if now - candidateSince >= 0.75 {
                let changed = activePresentation?.window != sample.window ||
                    activePresentation.map { abs($0.width / $0.height - ratio) > 0.002 } == true
                activePresentation = sample
                if changed {
                    LaunchLogFile.append("notice", "Desktop presentation follows client \(Int(sample.width))x\(Int(sample.height)), window=\(sample.window), mode=\(aspectRatio.rawValue)")
                }
            }
        } else {
            missingSince = missingSince ?? now
            if now - (missingSince ?? now) >= 0.75 {
                activePresentation = nil
                candidateWindow = 0
            }
        }
        setNeedsLayout()
    }

    @objc private func displayModeChanged() {
        // The guest can change resolution after launch without resizing this view.
        setNeedsLayout()
    }

    private func updateWindowGeometry() {
        guard let window, let scene = window.windowScene else { return }
        if presentationScene !== scene {
            restoreWindowGeometry()
            presentationScene = scene
            previousWindowSize = window.bounds.size
            switch scene.effectiveGeometry.resizingRestrictions {
            case .none: previousResizingRestrictions = .none
            case .uniform: previousResizingRestrictions = .uniform
            default: previousResizingRestrictions = .freeform
            }
        }
        var width: Int32 = 0, height: Int32 = 0
        winios_screen_size(&width, &height)
        guard width > 0, height > 0 else { return }
        let gameAspect = activePresentation.map { $0.width / $0.height }
        let aspect = CGFloat(aspectRatio.fixedRatio ?? gameAspect ?? (Double(width) / Double(height)))
        if let guestAspectRatio, abs(aspect - guestAspectRatio) <= 0.001 { return }
        guestAspectRatio = aspect
        // Match the guest's shape, then preserve it as the user resizes. This
        // removes letterboxing without stretching the picture or cropping cards.
        let targetHeight = max(360, max(640, window.bounds.width) / aspect)
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Vision(
            size: CGSize(width: targetHeight * aspect, height: targetHeight),
            resizingRestrictions: .uniform
        )) { error in
            LaunchLogFile.append("desktop", "Could not match game window aspect: \(error.localizedDescription)")
        }
    }

    func restoreWindowGeometry() {
        presentationTask?.cancel()
        presentationTask = nil
        activePresentation = nil
        appliedCompositorFrame = nil
        candidateWindow = 0
        guard let scene = presentationScene else { return }
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Vision(
            size: previousWindowSize, resizingRestrictions: previousResizingRestrictions
        )) { error in
            LaunchLogFile.append("desktop", "Could not restore launcher window: \(error.localizedDescription)")
        }
        presentationScene = nil
        previousWindowSize = nil
        guestAspectRatio = nil
    }

    func toggleKeyboard() {
        guard inputEnabled else { return }
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    private func map(_ point: CGPoint) -> (Int32, Int32)? {
        guard window != nil else { return nil }
        let position = convert(point, to: window)
        var x: Int32 = 0, y: Int32 = 0
        guard winios_desktop_point_from_window(position.x, position.y, &x, &y) != 0 else { return nil }
        pointer = (x, y)
        return pointer
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard inputEnabled, let (x, y) = map(recognizer.location(in: self)) else { return }
        pointerInput.hover(.init(x: x, y: y))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, activeTouch == nil, let touch = touches.first,
              let (x, y) = map(touch.location(in: self)) else { return }
        activeTouch = touch
        WindowsVRAudioDiagnostics.requestPlayback()
        let secondary = event?.buttonMask.contains(.secondary) == true
        // Pinch classification can overlap indirect pointing input on visionOS.
        // Sequence every desktop button so gaze never bypasses hover priming.
        pointerInput.begin(.init(x: x, y: y), secondary: secondary)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, let touch = activeTouch, touches.contains(touch),
              let (x, y) = map(touch.location(in: self)) else { return }
        pointerInput.move(.init(x: x, y: y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        _ = map(touch.location(in: self))
        releasePointer()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releasePointer(cancelled: true) }

    private func releasePointer(cancelled: Bool = false) {
        if cancelled { pointerInput.cancel() }
        else { pointerInput.end(.init(x: pointer.0, y: pointer.1)) }
        activeTouch = nil
    }

    func releaseInput() {
        releasePointer(cancelled: true)
        for key in keysHeld { winios_post_key(key, 0) }
        keysHeld.removeAll()
        resignFirstResponder()
    }

    func pulseKey(_ vk: Int32) {
        guard inputEnabled, !keysHeld.contains(vk) else { return }
        WindowsVRAudioDiagnostics.requestPlayback()
        winios_post_key(vk, 1)
        winios_post_key(vk, 0)
    }

    func rightClick() {
        guard inputEnabled, activeTouch == nil else { return }
        WindowsVRAudioDiagnostics.requestPlayback()
        let point = WindowsDesktopPointerInput.Point(x: pointer.0, y: pointer.1)
        pointerInput.begin(point, secondary: true)
        pointerInput.end(point)
    }

    func scroll(_ delta: Int32) {
        guard inputEnabled else { return }
        WindowsVRAudioDiagnostics.requestPlayback()
        winios_pointer(pointer.0, pointer.1, 0x0800, UInt32(bitPattern: delta))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputEnabled else { super.pressesBegan(presses, with: event); return }
        var other: Set<UIPress> = []
        for press in presses {
            if let key = press.key, let vk = WindowsDesktopKeyboard.virtualKey(hidUsage: key.keyCode.rawValue) {
                if keysHeld.insert(vk).inserted {
                    WindowsVRAudioDiagnostics.requestPlayback()
                    winios_post_key(vk, 1)
                }
            } else { other.insert(press) }
        }
        // Handled hardware keys bypass UIKit's text insertion, avoiding duplicates.
        if !other.isEmpty { super.pressesBegan(other, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var other: Set<UIPress> = []
        for press in presses {
            if let key = press.key, let vk = WindowsDesktopKeyboard.virtualKey(hidUsage: key.keyCode.rawValue) {
                if keysHeld.remove(vk) != nil { winios_post_key(vk, 0) }
            } else { other.insert(press) }
        }
        if !other.isEmpty { super.pressesEnded(other, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    var hasText: Bool { true }
    func insertText(_ text: String) {
        guard inputEnabled, keysHeld.isEmpty else { return }
        let strokes = text.map { WindowsDesktopKeyboard.stroke(for: $0) }
        guard strokes.allSatisfy({ $0 != nil }) else {
            controls?.inputMessage = L("This keyboard currently supports basic Latin characters and US punctuation.", "Diese Tastatur unterstützt derzeit lateinische Grundzeichen und US-Satzzeichen.")
            return
        }
        controls?.inputMessage = nil
        for stroke in strokes.compactMap({ $0 }) {
            if stroke.shift { winios_post_key(0x10, 1) }
            pulseKey(stroke.key)
            if stroke.shift { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() { pulseKey(0x08) }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
}
