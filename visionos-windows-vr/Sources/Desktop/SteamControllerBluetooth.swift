import Foundation
import CoreBluetooth

/// Uses the public CoreBluetooth path used by Valve's SDL iOS backend. Triton
/// is not required to appear in GCController.controllers(). No raw-HID or
/// private Apple API is used. All delegates run on the main queue.
@MainActor
final class SteamControllerBluetooth: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
    private static let input45 = CBUUID(string: "100F6C7A-1735-4313-B402-38567131E5F3")
    private static let input47 = CBUUID(string: "100F6C7C-1735-4313-B402-38567131E5F3")
    private static let feature = CBUUID(string: "100F6C34-1735-4313-B402-38567131E5F3")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var feature: CBCharacteristic?
    private var reportID: UInt8 = 0
    private var started = false
    private var active = false
    private var timer: Task<Void, Never>?
    private var connectedAt: TimeInterval = 0
    private var lastPacketAt: TimeInterval = 0
    private var lastModeWrite: TimeInterval = 0
    private var receivedInput = false
    private var releasedStaleInput = false
    private var rejectedPacketLogged = false
    var stateChanged: (winios_gamepad?) -> Void = { _ in }
    var diagnostic: (String) -> Void = { _ in }

    func start() {
        guard !started else { return }
        started = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else { updateConnection() }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                self?.tick()
            }
        }
    }

    func stop() {
        started = false
        setActive(false)
        timer?.cancel()
        timer = nil
        if let peripheral {
            if let input, input.isNotifying { peripheral.setNotifyValue(false, for: input) }
            central?.cancelPeripheralConnection(peripheral)
        }
        clearConnection()
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        writeMouseMode(enabled: !value)
        if !value, receivedInput {
            var neutral = winios_gamepad()
            neutral.connected = 1
            stateChanged(neutral)
        }
        if value, started { updateConnection() }
    }

    private func updateConnection() {
        guard started, let central, central.state == .poweredOn, peripheral == nil else { return }
        // SDL uses Device Information (180A): Valve's custom service need not
        // be present in the advertisement even when the device is paired.
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.service, CBUUID(string: "180A")])
        if let candidate = connected.first(where: { $0.name?.hasPrefix("Steam") == true }) {
            connect(candidate)
            return
        }
        // Pairing and discovery belong to visionOS Settings. Retry retrieval
        // in tick() so a controller connected later is picked up automatically.
    }

    private func connect(_ candidate: CBPeripheral) {
        guard started, peripheral == nil, let central else { return }
        peripheral = candidate
        candidate.delegate = self
        connectedAt = ProcessInfo.processInfo.systemUptime
        receivedInput = false
        releasedStaleInput = false
        rejectedPacketLogged = false
        diagnostic("Steam BLE connecting to \(candidate.name ?? "Steam Controller")")
        central.connect(candidate)
    }

    private func clearConnection() {
        peripheral?.delegate = nil
        peripheral = nil
        input = nil
        feature = nil
        reportID = 0
        receivedInput = false
        lastPacketAt = 0
        lastModeWrite = 0
        stateChanged(nil)
    }

    private func tick() {
        guard started, let central, central.state == .poweredOn else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if peripheral == nil {
            updateConnection()
            return
        }
        if !receivedInput, now - connectedAt > 15, let peripheral {
            diagnostic("Steam BLE initialization timed out")
            central.cancelPeripheralConnection(peripheral)
            clearConnection()
            return
        }
        // Notification registration can be delayed by Apple's pairing dialog.
        if let input, !input.isNotifying { peripheral?.setNotifyValue(true, for: input) }
        if active, receivedInput {
            if now - lastModeWrite >= 3 { writeMouseMode(enabled: false) }
            if now - lastPacketAt > 2, !releasedStaleInput {
                releasedStaleInput = true
                var neutral = winios_gamepad()
                neutral.connected = 1
                stateChanged(neutral)
                diagnostic("Steam BLE input stalled; held controls released")
            }
        }
    }

    /// Volatile setting used by SDL to suppress the controller's built-in
    /// mouse/keyboard while the game owns it. No firmware or pairing changes.
    private func writeMouseMode(enabled: Bool) {
        guard let peripheral, peripheral.state == .connected, let feature,
              feature.properties.contains(.write) else { return }
        var bytes = [UInt8](repeating: 0, count: 63)
        bytes[0] = 0x87 // SET_SETTINGS_VALUES
        bytes[1] = 3
        bytes[2] = 9 // SETTING_LIZARD_MODE
        bytes[3] = enabled ? 1 : 0
        peripheral.writeValue(Data(bytes), for: feature, type: .withResponse)
        lastModeWrite = ProcessInfo.processInfo.systemUptime
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard started else { return }
        diagnostic("Steam BLE manager state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn: updateConnection()
        case .unauthorized: diagnostic("Steam BLE access not allowed in Settings"); clearConnection()
        case .poweredOff: diagnostic("Steam BLE Bluetooth is off"); clearConnection()
        case .unsupported: diagnostic("Steam BLE unavailable"); clearConnection()
        default: clearConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard started, self.peripheral === peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        diagnostic("Steam BLE connection failed: \(error?.localizedDescription ?? "unknown error")")
        clearConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        diagnostic("Steam BLE disconnected: \(error?.localizedDescription ?? "connection closed")")
        clearConnection()
        if started { updateConnection() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard started, self.peripheral === peripheral else { return }
        if let service = peripheral.services?.first(where: { $0.uuid == Self.service }), error == nil {
            peripheral.discoverCharacteristics(nil, for: service)
        } else {
            diagnostic("Steam BLE Valve service unavailable: \(error?.localizedDescription ?? "service missing")")
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard started, self.peripheral === peripheral, error == nil else { return }
        let characteristics = service.characteristics ?? []
        feature = characteristics.first(where: { $0.uuid == Self.feature })
        // New timestamped reports are preferred when both are available.
        input = characteristics.first(where: { $0.uuid == Self.input47 }) ??
            characteristics.first(where: { $0.uuid == Self.input45 })
        guard let input else {
            diagnostic("Steam BLE Triton input characteristic missing")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        reportID = input.uuid == Self.input47 ? 0x47 : 0x45
        diagnostic("Steam BLE input characteristic ready, report=\(String(reportID, radix: 16))")
        peripheral.setNotifyValue(true, for: input)
        if active { writeMouseMode(enabled: false) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard started, self.peripheral === peripheral, characteristic === input else { return }
        if let error {
            diagnostic("Steam BLE notifications failed: \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard started, self.peripheral === peripheral, characteristic === input else { return }
        guard error == nil, let data = characteristic.value,
              let state = SteamControllerReport.decode(data, reportID: reportID) else {
            if !rejectedPacketLogged {
                rejectedPacketLogged = true
                diagnostic("Steam BLE rejected input: bytes=\(characteristic.value?.count ?? 0), error=\(error?.localizedDescription ?? "invalid report")")
            }
            return
        }
        lastPacketAt = ProcessInfo.processInfo.systemUptime
        releasedStaleInput = false
        if !receivedInput {
            receivedInput = true
            diagnostic("Steam BLE receiving valid Triton reports")
        }
        stateChanged(state)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard started, self.peripheral === peripheral, let error else { return }
        diagnostic("Steam BLE mode setting failed: \(error.localizedDescription)")
    }
}
