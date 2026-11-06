import Foundation

/// A gaze pinch can teleport the mouse without any preceding hover frames.
/// Give the guest a move-only update before pressing, and a pressed update
/// before releasing. Keep each gesture's coordinates and button together.
@MainActor
final class WindowsDesktopPointerInput {
    struct Point: Equatable { let x: Int32; let y: Int32 }
    private final class Gesture {
        let origin: Point
        var position: Point
        let down: UInt32
        let up: UInt32
        var pressed = false
        var released = false
        var frame: UInt64 = 0
        var time: TimeInterval = 0
        init(_ point: Point, secondary: Bool) {
            origin = point; position = point
            down = secondary ? 0x0008 : 0x0002
            up = secondary ? 0x0010 : 0x0004
        }
    }
    private let frame: () -> UInt64
    private let now: () -> TimeInterval
    private let send: (Int32, Int32, UInt32, UInt32) -> Void
    private var queue: [Gesture] = []
    private var active: Gesture?
    private var ticker: Task<Void, Never>?
    private var sent: Point?

    init(frame: @escaping () -> UInt64,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         send: @escaping (Int32, Int32, UInt32, UInt32) -> Void) {
        self.frame = frame; self.now = now; self.send = send
    }

    func hover(_ point: Point) {
        guard queue.isEmpty else { return }
        movePointer(point)
    }

    func begin(_ point: Point, secondary: Bool = false) {
        guard active == nil else { return }
        let gesture = Gesture(point, secondary: secondary)
        active = gesture
        queue.append(gesture)
        if queue.count == 1 { start(gesture) }
        if ticker == nil {
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(8)) }
                    catch { return }
                    guard let self else { return }
                    self.tick()
                    if self.queue.isEmpty { self.ticker = nil; return }
                }
            }
        }
    }

    func move(_ point: Point) {
        guard let active else { return }
        active.position = point
        tick()
    }

    func end(_ point: Point) {
        guard let active else { return }
        active.position = point
        active.released = true
        self.active = nil
        tick()
    }

    func cancel() {
        ticker?.cancel(); ticker = nil
        if let first = queue.first, first.pressed {
            let point = sent ?? first.origin
            send(point.x, point.y, 0x8001 | first.up, 0)
        }
        queue.removeAll()
        active = nil
    }

    private func movePointer(_ point: Point) {
        send(point.x, point.y, 0x8001, 0)
        sent = point
    }

    private func start(_ gesture: Gesture) {
        movePointer(gesture.origin)
        gesture.frame = frame()
        gesture.time = now()
    }

    private func press(_ gesture: Gesture) {
        send(gesture.origin.x, gesture.origin.y, 0x8001 | gesture.down, 0)
        sent = gesture.origin
        gesture.pressed = true
        gesture.frame = frame()
        gesture.time = now()
    }

    func tick() {
        guard let gesture = queue.first else { return }
        if !gesture.pressed {
            // The first submission can already be in flight when the move is
            // queued. A second gives the guest a full move/hover update.
            // Bound latency for GDI windows or a paused renderer.
            if frame() &- gesture.frame >= 2 || now() - gesture.time >= 0.15 { press(gesture) }
            return
        }
        guard frame() &- gesture.frame >= 2 || now() - gesture.time >= 0.10 else { return }
        if gesture.position != sent { movePointer(gesture.position) }
        if gesture.released {
            // Windows ignores button-event coordinates without MOVE. Always
            // publish the release location before the guest sees button-up.
            send(gesture.position.x, gesture.position.y, 0x8001 | gesture.up, 0)
            sent = gesture.position
            queue.removeFirst()
            if let next = queue.first { start(next) }
        }
    }
}
