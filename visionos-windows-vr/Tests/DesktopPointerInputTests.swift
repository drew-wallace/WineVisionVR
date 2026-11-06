import Foundation

@MainActor private final class Fixture {
    typealias Point = WindowsDesktopPointerInput.Point
    struct Event { let point: Point; let flags: UInt32 }
    var frame: UInt64 = 0
    var time: TimeInterval = 0
    var cursor = Point(x: 10, y: 10)
    var hover = Point(x: 10, y: 10)
    var hits: [Point] = []
    var events: [Event] = []
    lazy var input = WindowsDesktopPointerInput(frame: { self.frame }, now: { self.time }) { x, y, flags, _ in
        let point = Point(x: x, y: y)
        self.events.append(Event(point: point, flags: flags))
        if flags & 1 != 0 { self.cursor = point }
        // The observed game chooses the button target from its existing hover
        // state. Coordinates on a down event alone do not update that state.
        if flags & 0x000a != 0 { self.hits.append(self.hover) }
    }
    func submitFrame() {
        hover = cursor
        frame += 1
        input.tick()
    }
}

@main struct DesktopPointerInputTests {
    @MainActor static func main() {
        typealias Point = WindowsDesktopPointerInput.Point
        let a = Point(x: 150, y: 200), b = Point(x: 700, y: 400)
        let quick = Fixture()
        quick.input.begin(a)
        quick.input.end(a)
        precondition(quick.events.count == 1 && quick.events[0].flags == 0x8001)
        quick.submitFrame()
        precondition(quick.hits.isEmpty, "Allow a complete hover update before pressing")
        quick.submitFrame()
        precondition(quick.hits == [a], "First pinch must select the new hover target")
        quick.submitFrame()
        precondition(quick.events.last?.flags == 0x8003, "Quick pinch must survive a pressed update")
        quick.submitFrame()
        precondition(quick.events.last?.flags == 0x8005)
        quick.input.begin(b); quick.input.end(b)
        for _ in 0..<4 { quick.submitFrame() }
        precondition(quick.hits == [a, b], "Moving gaze must not click the previous target")
        quick.input.cancel()

        let queued = Fixture()
        queued.input.begin(a); queued.input.end(a)
        queued.input.begin(b); queued.input.end(b)
        queued.input.hover(Point(x: 999, y: 999))
        precondition(queued.cursor == a, "Hover cannot move a queued pinch's anchor")
        for _ in 0..<8 { queued.submitFrame() }
        precondition(queued.hits == [a, b], "Rapid pinches retain their own ordered targets")
        precondition(queued.events.filter { $0.flags & 4 != 0 }.count == 2)
        queued.input.cancel()

        let drag = Fixture()
        drag.input.begin(a); drag.input.move(b)
        precondition(drag.cursor == a, "Drag motion must not replace the initial press target")
        for _ in 0..<4 { drag.submitFrame() }
        precondition(drag.hits == [a] && drag.cursor == b)
        let end = Point(x: 800, y: 500)
        drag.input.end(end)
        precondition(drag.events.last?.point == end && drag.events.last?.flags == 0x8005,
                     "Release must carry MOVE so Windows uses its actual coordinates")
        drag.input.cancel()

        let cancelled = Fixture()
        cancelled.input.begin(a); cancelled.input.cancel()
        for _ in 0..<5 { cancelled.submitFrame() }
        precondition(cancelled.hits.isEmpty, "Cancelled/focus-lost priming must not click later")
        cancelled.input.begin(a)
        cancelled.submitFrame(); cancelled.submitFrame()
        cancelled.input.cancel()
        precondition(cancelled.events.last?.flags == 0x8005, "Cancellation releases an emitted press")

        let fallback = Fixture()
        fallback.input.begin(a, secondary: true); fallback.input.end(a)
        fallback.time = 0.151; fallback.input.tick()
        precondition(fallback.events.last?.flags == 0x8009)
        fallback.time = 0.252; fallback.input.tick()
        precondition(fallback.events.last?.flags == 0x8011, "GDI/non-rendering windows must not stall input")
        fallback.input.cancel()

        print("PASS: new-target hover, quick/queued pinches, anchored drag, release location, cancellation and fallback")
    }
}
