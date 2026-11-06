import Foundation
import GameController
import Darwin

/// Publishes ordinary Bluetooth/USB gamepads to Wine's four XInput slots.
/// All discovery, callbacks and sampling belong to the main actor. Spatial
/// accessories remain owned by the immersive controller provider.
@MainActor
final class WindowsDesktopGamepad {
    private typealias SetState = @convention(c) (Int32, UnsafePointer<winios_gamepad>?) -> Void
    private static let setState: SetState? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "winios_gamepad_set_state") else { return nil }
        return unsafeBitCast(symbol, to: SetState.self)
    }()
    static var isAvailable: Bool { setState != nil }
    private typealias SetHIDState = @convention(c) (UnsafePointer<winios_hidpad>?) -> Void
    private static let setHIDState: SetHIDState? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "winios_hidpad_set_state") else { return nil }
        return unsafeBitCast(symbol, to: SetHIDState.self)
    }()

    private var controllers = [GCController?](repeating: nil, count: 4)
    private var profiles = [GCExtendedGamepad?](repeating: nil, count: 4)
    private var observers: [NSObjectProtocol] = []
    private var samplingTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var lastDiscovery: String?
    private var started = false
    private var enabled = false
    private var steamControllerState: winios_gamepad?
    private var steamControllerSlot: Int?
    private let publish: (Int32, winios_gamepad?) -> Void
    private let controllerDiscovery: (() -> [GCController])?
    var controllersChanged: ([String]) -> Void = { _ in }
    var diagnostic: (String) -> Void = { _ in }
    var inputReceived: () -> Void = {}
    private var remainingInputDiagnostics = 12
    private var lastInputDiagnostic: TimeInterval = 0

    init(discover: (() -> [GCController])? = nil, publish: ((Int32, winios_gamepad?) -> Void)? = nil) {
        controllerDiscovery = discover
        self.publish = publish ?? { index, state in
            if var state { Self.setState?(index, &state) }
            else { Self.setState?(index, nil) }
            // The optional Windows HID device consumes the same player-1
            // sample. It is enumerated only when MADEIRA_HIDPAD is enabled.
            if index == 0 {
                if var hid = Self.hidState(state) { Self.setHIDState?(&hid) }
                else { Self.setHIDState?(nil) }
            }
        }
    }

    static func hidState(_ state: winios_gamepad?) -> winios_hidpad? {
        guard let state, state.connected != 0 else { return nil }
        var hid = winios_hidpad()
        hid.connected = 1
        hid.buttons = UInt32(state.buttons)
        hid.lx = state.lx; hid.ly = state.ly; hid.rx = state.rx; hid.ry = state.ry
        hid.left_trigger = state.left_trigger; hid.right_trigger = state.right_trigger
        hid.battery = UInt8(WINIOS_HIDPAD_BATTERY_UNKNOWN)
        if state.left_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_L2 }
        if state.right_trigger > 25 { hid.buttons |= WINIOS_HIDPAD_R2 }
        return hid
    }

    func start() {
        guard !started else { return }
        started = true
        remainingInputDiagnostics = 12
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.discoverControllers() }
            })
        }
        // A pad paired before the game launched needs no new connect event.
        discoverControllers()
        // visionOS may expose a pre-paired controller only after the scene's
        // GCEventInteraction starts receiving input, without a new connection.
        discoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                self?.discoverControllers()
            }
        }
    }

    func stop() {
        started = false
        enabled = false
        samplingTask?.cancel()
        samplingTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        steamControllerState = nil
        steamControllerSlot = nil
        refreshControllers([])
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { discoverControllers() }
        updateSampling()
        sample()
    }

    private func discoverControllers() {
        let connected = controllerDiscovery?() ?? GCController.controllers()
        let inventory = "discovery found \(connected.count) device(s): " + connected.map {
            "\($0.vendorName ?? $0.productCategory) category=\($0.productCategory) extended=\($0.extendedGamepad != nil) snapshot=\($0.isSnapshot)"
        }.joined(separator: "; ")
        let inventoryChanged = inventory != lastDiscovery
        if inventoryChanged {
            lastDiscovery = inventory
            diagnostic(inventory)
        }
        let supported = connected.filter { controller in
            guard (controllerDiscovery != nil || !controller.isSnapshot), controller.extendedGamepad != nil else { return false }
            #if os(visionOS)
            return controller.productCategory != GCProductCategorySpatialController
            #else
            return true
            #endif
        }
        // Keep the same cached live profile and callback until membership
        // changes; some controllers return stale axes on a re-fetched profile.
        let previous = Set(controllers.compactMap { $0.map(ObjectIdentifier.init) })
        let current = Set(supported.map(ObjectIdentifier.init))
        let capacity = 4 - (steamControllerSlot == nil ? 0 : 1)
        if !previous.isSubset(of: current) || previous.count < min(capacity, current.count) {
            refreshControllers(supported)
        } else if inventoryChanged, previous.isEmpty { reportControllers() }
    }

    // Also accepts virtual controllers for exercising the complete mapping.
    func refreshControllers(_ live: [GCController]) {
        for index in controllers.indices {
            guard let old = controllers[index], !live.contains(where: { $0 === old }) else { continue }
            profiles[index]?.valueChangedHandler = nil
            controllers[index] = nil
            profiles[index] = nil
            // Publish removal before reusing the slot, even during a reconnect.
            publish(Int32(index), nil)
        }
        for controller in live {
            guard !controllers.contains(where: { $0 === controller }),
                  let profile = controller.extendedGamepad,
                  let index = controllers.indices.first(where: { controllers[$0] == nil && $0 != steamControllerSlot }) else { continue }
            controller.handlerQueue = .main
            controllers[index] = controller
            profiles[index] = profile
            profile.valueChangedHandler = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        }
        reportControllers()
        updateSampling()
        sample()
    }

    func setSteamControllerState(_ state: winios_gamepad?) {
        guard let state, state.connected != 0 else {
            steamControllerState = nil
            if let index = steamControllerSlot { publish(Int32(index), nil) }
            steamControllerSlot = nil
            reportControllers()
            if started { discoverControllers() }
            return
        }
        if steamControllerSlot == nil {
            guard let index = profiles.firstIndex(where: { $0 == nil }) else {
                diagnostic("Steam Controller has no free XInput player slot")
                return
            }
            steamControllerSlot = index
            diagnostic("Steam Controller assigned to XInput slot \(index)")
        }
        let wasConnected = steamControllerState != nil
        steamControllerState = state
        if !wasConnected { reportControllers() }
        sample()
    }

    private func reportControllers() {
        controllersChanged(controllers.indices.compactMap { index in
            if index == steamControllerSlot { return "Steam Controller (2026)" }
            return controllers[index].map { $0.vendorName ?? $0.productCategory }
        })
    }

    private func updateSampling() {
        // Events publish immediately; a small polling fallback keeps held axes
        // fresh on controllers that coalesce value-change callbacks.
        guard enabled, profiles.contains(where: { $0 != nil }) else {
            samplingTask?.cancel()
            samplingTask = nil
            return
        }
        guard samplingTask == nil else { return }
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                do { try await Task.sleep(for: .milliseconds(8)) }
                catch { return }
            }
        }
    }

    func sample() {
        for index in profiles.indices {
            var state = winios_gamepad()
            if index == steamControllerSlot, let steamControllerState {
                state = steamControllerState
                if !enabled { state = winios_gamepad(); state.connected = 1 }
            } else if let pad = profiles[index] {
                state.connected = 1
                // Preserve device identity while inactive, releasing every control.
                if enabled {
                    let buttons: [(GCControllerButtonInput?, UInt16)] = [
                        (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002),
                        (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
                        (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
                        (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
                        (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
                        (pad.buttonA, 0x1000), (pad.buttonB, 0x2000),
                        (pad.buttonX, 0x4000), (pad.buttonY, 0x8000)
                    ]
                    for (button, mask) in buttons where button?.isPressed == true { state.buttons |= mask }
                    state.left_trigger = Self.trigger(pad.leftTrigger.value)
                    state.right_trigger = Self.trigger(pad.rightTrigger.value)
                    state.lx = Self.axis(pad.leftThumbstick.xAxis.value)
                    state.ly = Self.axis(pad.leftThumbstick.yAxis.value)
                    state.rx = Self.axis(pad.rightThumbstick.xAxis.value)
                    state.ry = Self.axis(pad.rightThumbstick.yAxis.value)
                }
            } else { publish(Int32(index), nil); continue }
            publish(Int32(index), state)
            let now = ProcessInfo.processInfo.systemUptime
            let hasInput = state.buttons != 0 || state.left_trigger != 0 || state.right_trigger != 0 ||
                abs(Int(state.lx)) > 8000 || abs(Int(state.ly)) > 8000 ||
                abs(Int(state.rx)) > 8000 || abs(Int(state.ry)) > 8000
            if enabled, hasInput { inputReceived() }
            if enabled, hasInput, remainingInputDiagnostics > 0, now - lastInputDiagnostic >= 1 {
                remainingInputDiagnostics -= 1
                lastInputDiagnostic = now
                diagnostic("published input slot=\(index) buttons=\(String(state.buttons, radix: 16)) triggers=\(state.left_trigger),\(state.right_trigger) sticks=\(state.lx),\(state.ly),\(state.rx),\(state.ry)")
            }
        }
    }

    // XInput games apply their own dead zones; keep the full signed range and
    // GameController's positive-up Y convention, with independent triggers.
    static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let value = max(-1, min(1, value))
        return Int16((value * (value < 0 ? 32768 : 32767)).rounded())
    }

    static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0, min(1, value)) * 255).rounded())
    }
}
