import Foundation

/// Steam Controller 2026 (Triton) BLE reports. Protocol reference: SDL commit
/// bd9f6ca9ff0e9509f49980fc1b70837f54b6f244, hidapi/ios/hid.m and
/// joystick/hidapi/steam/controller_structs.h. This is an independent decoder;
/// BLE notification payloads omit the HID report ID and begin with a sequence.
enum SteamControllerReport {
    static func decode(_ data: Data, reportID: UInt8) -> winios_gamepad? {
        guard reportID == 0x45 || reportID == 0x47, data.count == 45 else { return nil }
        let bytes = Array(data)
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func axis(_ offset: Int) -> Int16 { Int16(bitPattern: u16(offset)) }
        func trigger(_ offset: Int) -> UInt8 {
            // Triton's signed 16-bit trigger fields have a 0...32767 range.
            UInt8((max(0, Int(axis(offset))) * 255 + 16383) / 32767)
        }
        let buttons = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24
        var state = winios_gamepad()
        state.connected = 1
        let mapping: [(UInt32, UInt16)] = [
            (0x000001, 0x1000), (0x000002, 0x2000), // A, B
            (0x000004, 0x4000), (0x000008, 0x8000), // X, Y
            (0x000020, 0x0080), (0x008000, 0x0040), // right/left stick click
            // SDL maps Triton's VIEW bit to Start and MENU bit to Back;
            // the protocol names do not match the usual Xbox button names.
            (0x000040, 0x0010), (0x004000, 0x0020), // Start, Select
            (0x000200, 0x0200), (0x080000, 0x0100), // right/left shoulder
            (0x000400, 0x0002), (0x000800, 0x0008), // down, right
            (0x001000, 0x0004), (0x002000, 0x0001), // left, up
            (0x010000, 0x0400) // Steam / Guide
        ]
        for (source, destination) in mapping where buttons & source != 0 { state.buttons |= destination }
        state.left_trigger = trigger(5)
        state.right_trigger = trigger(7)
        state.lx = axis(9)
        state.ly = axis(11)
        state.rx = axis(13)
        state.ry = axis(15)
        return state
    }
}
