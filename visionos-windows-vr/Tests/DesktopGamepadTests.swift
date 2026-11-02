import Foundation
import GameController

@main
struct DesktopGamepadTests {
    @MainActor
    static func main() async throws {
        precondition(MemoryLayout<winios_gamepad>.size == 20, "Wine snapshot ABI")
        precondition(MemoryLayout<winios_hidpad>.size == 48, "Windows HID snapshot ABI")
        precondition(WindowsDesktopGamepad.axis(-1) == -32768)
        precondition(WindowsDesktopGamepad.axis(1) == 32767)
        precondition(WindowsDesktopGamepad.axis(-2) == -32768)
        precondition(WindowsDesktopGamepad.axis(.nan) == 0)
        precondition(WindowsDesktopGamepad.axis(.infinity) == 0)
        precondition(WindowsDesktopGamepad.trigger(-1) == 0)
        precondition(WindowsDesktopGamepad.trigger(2) == 255)
        precondition(WindowsDesktopGamepad.trigger(0.5) == 128)
        precondition(WindowsDesktopGamepad.trigger(.nan) == 0)

        let controllers = (0..<5).map { _ in GCController.withExtendedGamepad() }
        var available: [GCController] = controllers
        let adapter = WindowsDesktopGamepad(discover: { available }) { index, state in
            if var state { winios_gamepad_set_state(index, &state) }
            else { winios_gamepad_set_state(index, nil) }
            if index == 0 {
                if var hid = WindowsDesktopGamepad.hidState(state) { winios_hidpad_set_state(&hid) }
                else { winios_hidpad_set_state(nil) }
            }
        }
        func read(_ index: Int32 = 0) -> winios_gamepad {
            var state = winios_gamepad()
            _ = winios_gamepad_get_state(index, &state)
            return state
        }

        let pad = controllers[0].extendedGamepad!
        adapter.refreshControllers(controllers)
        precondition((0..<4).allSatisfy { read(Int32($0)).connected == 1 })
        precondition(read().buttons == 0, "Connected, neutral before launch")
        adapter.setEnabled(true)

        let buttons: [(GCControllerButtonInput?, UInt16)] = [
            (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002),
            (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
            (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
            (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
            (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
            (pad.buttonA, 0x1000), (pad.buttonB, 0x2000),
            (pad.buttonX, 0x4000), (pad.buttonY, 0x8000)
        ]
        for (button, mask) in buttons {
            guard let button else { continue }
            // Direction-pad buttons derive from its axes in Apple's snapshots.
            if mask <= 0x0008 {
                pad.dpad.setValueForXAxis(mask == 4 ? -1 : mask == 8 ? 1 : 0,
                                          yAxis: mask == 1 ? 1 : mask == 2 ? -1 : 0)
            } else { button.setValue(1) }
            adapter.sample()
            precondition(read().buttons == mask, "Wrong XInput button bit \(mask)")
            if mask <= 0x0008 { pad.dpad.setValueForXAxis(0, yAxis: 0) }
            else { button.setValue(0) }
            adapter.sample()
            precondition(read().buttons == 0, "Button release")
        }
        pad.buttonA.setValue(1)
        pad.buttonY.setValue(1)
        pad.leftThumbstick.setValueForXAxis(-1, yAxis: 1)
        pad.rightThumbstick.setValueForXAxis(1, yAxis: -1)
        pad.leftTrigger.setValue(0.25)
        pad.rightTrigger.setValue(0.75)
        adapter.sample()
        let pressed = read()
        var hid = winios_hidpad()
        precondition(winios_hidpad_get_state(&hid) == 1)
        precondition(hid.buttons & 0xffff == UInt32(pressed.buttons))
        precondition(hid.buttons & WINIOS_HIDPAD_L2 != 0 && hid.buttons & WINIOS_HIDPAD_R2 != 0)
        precondition(hid.lx == pressed.lx && hid.ry == pressed.ry && hid.right_trigger == pressed.right_trigger)
        precondition(pressed.buttons == 0x9000)
        precondition(pressed.lx == -32768 && pressed.ly == 32767)
        precondition(pressed.rx == 32767 && pressed.ry == -32768)
        precondition(pressed.left_trigger == 64 && pressed.right_trigger == 191)
        adapter.sample()
        precondition(read().packet == pressed.packet, "Unchanged input must not advance packet")

        adapter.setEnabled(false)
        let neutral = read()
        precondition(neutral.connected == 1 && neutral.buttons == 0)
        precondition(neutral.lx == 0 && neutral.ly == 0 && neutral.rx == 0 && neutral.ry == 0)
        precondition(neutral.left_trigger == 0 && neutral.right_trigger == 0)
        precondition(winios_hidpad_get_state(&hid) == 1 && hid.buttons == 0 && hid.lx == 0)
        pad.buttonB.setValue(1)
        adapter.sample()
        precondition(read().buttons == 0, "Late input must stay neutral while inactive")
        adapter.setEnabled(true)
        precondition(read().buttons == 0xb000, "Resume held state")

        // Keep player 2 in slot 1 after player 1 leaves; the waiting fifth pad
        // takes slot 0 without moving any of the remaining players.
        controllers[1].extendedGamepad!.buttonX.setValue(1)
        available = Array(controllers.dropFirst())
        adapter.refreshControllers(available)
        precondition(read().connected == 1 && read().buttons == 0)
        precondition(read(1).buttons == 0x4000, "Stable player slots")
        pad.buttonA.setValue(1)
        adapter.sample()
        precondition(read().buttons == 0, "Disconnected controller cannot publish")

        adapter.stop()
        precondition((0..<4).allSatisfy { read(Int32($0)).connected == 0 })
        precondition(winios_hidpad_get_state(&hid) == 0)
        adapter.sample()
        precondition(read().connected == 0, "Stopped adapter stays disconnected")
        // A pre-paired controller can become visible after the scene starts
        // accepting input, with no GameController connect notification.
        available = []
        adapter.start()
        precondition(read().connected == 0)
        available = [controllers[1]]
        adapter.setEnabled(true)
        precondition(read().connected == 1, "Rescan after claiming input focus")
        available = [controllers[1], controllers[2]]
        try await Task.sleep(for: .milliseconds(1200))
        precondition(read(1).connected == 1, "Delayed discovery without a notification")
        adapter.stop()
        available = [controllers[0]]
        try await Task.sleep(for: .milliseconds(1100))
        precondition(read().connected == 0, "Teardown cancels periodic discovery")
        adapter.stop()

        // Known Triton BLE layout: the report ID belongs to the characteristic,
        // not byte 0 (the sequence counter). Test both firmware report variants.
        var report = [UInt8](repeating: 0, count: 45)
        func write16(_ offset: Int, _ value: UInt16) {
            report[offset] = UInt8(truncatingIfNeeded: value)
            report[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        report[0] = 0x47 // Sequence may coincide with a report ID; never strip it.
        write16(5, 32767)
        write16(7, 16384)
        write16(9, 0x8000)
        write16(11, 0x7fff)
        write16(13, 0x7fff)
        write16(15, 0x8000)
        let steamButtons: [(UInt32, UInt16)] = [
            (1, 0x1000), (2, 0x2000), (4, 0x4000), (8, 0x8000),
            (0x20, 0x80), (0x8000, 0x40),
            // SDL's physical Start/Select mapping, despite the protocol's
            // counterintuitive VIEW/MENU names. Exercise both report IDs.
            (0x40, 0x10), (0x4000, 0x20),
            (0x200, 0x200), (0x80000, 0x100), (0x400, 2), (0x800, 8),
            (0x1000, 4), (0x2000, 1), (0x10000, 0x400)
        ]
        for id: UInt8 in [0x45, 0x47] {
            for (source, expected) in steamButtons {
                for offset in 0..<4 { report[offset + 1] = UInt8(truncatingIfNeeded: source >> (offset * 8)) }
                let decoded = SteamControllerReport.decode(Data(report), reportID: id)!
                precondition(decoded.buttons == expected, "Triton button mapping")
                precondition(decoded.left_trigger == 255 && decoded.right_trigger == 128)
                precondition(decoded.lx == -32768 && decoded.ly == 32767)
                precondition(decoded.rx == 32767 && decoded.ry == -32768)
            }
        }
        for length in 0..<45 {
            precondition(SteamControllerReport.decode(Data(report.prefix(length)), reportID: 0x45) == nil)
        }
        precondition(SteamControllerReport.decode(Data(report + [0]), reportID: 0x45) == nil)
        precondition(SteamControllerReport.decode(Data(report), reportID: 0x03) == nil, "No legacy/unknown report guessing")
        write16(5, 0xffff)
        precondition(SteamControllerReport.decode(Data(report), reportID: 0x45)!.left_trigger == 0)

        available = []
        adapter.start()
        adapter.setEnabled(true)
        let steam = SteamControllerReport.decode(Data(report), reportID: 0x47)!
        adapter.setSteamControllerState(steam)
        precondition(read().connected == 1 && read().buttons == steam.buttons)
        adapter.sample()
        precondition(read().buttons == steam.buttons, "GC sampling must not overwrite Steam BLE input")
        available = [controllers[1]]
        adapter.refreshControllers(available)
        precondition(read().buttons == steam.buttons && read(1).buttons == 0x4000, "Steam and standard pads get separate slots")
        adapter.setEnabled(false)
        adapter.setSteamControllerState(steam)
        precondition(read().connected == 1 && read().buttons == 0 && read().lx == 0, "Inactive BLE input stays neutral")
        adapter.setEnabled(true)
        precondition(read().buttons == steam.buttons)
        adapter.setSteamControllerState(nil)
        precondition(read().connected == 0, "BLE disconnect releases its slot")
        precondition(read(1).connected == 1, "BLE disconnect preserves another player's slot")
        adapter.stop()
        precondition(read(1).connected == 0)
        print("PASS: Apple gamepads and Triton BLE reports → real Wine snapshot; mappings, malformed packets, stable slots, coexistence, inactive input, delayed discovery and teardown")
    }
}
