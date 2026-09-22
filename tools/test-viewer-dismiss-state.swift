// Run: swift tools/test-viewer-dismiss-state.swift
// Compile the production pure policy directly, avoiding a second implementation.
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("PhotoVault/PhotoViewerPresentationBridge.swift"), encoding: .utf8)
let start = source.range(of: "struct ViewerDismissInteraction {")!.lowerBound
let end = source.range(of: "// MARK: - Presentation input")!.lowerBound
let tests = #"""
func expect(_ result: Bool, _ message: String) { precondition(result, message) }
let cases: [(Bool, CGFloat, CGFloat, Bool, Bool)] = [
    (true, 0, 300, false, true), (false, 500, 0, false, false),
    (false, 20, 300, false, false), (true, 0, 300, true, false),
    (false, 300, 100, false, false), (false, 0, 0, false, false),
    (false, 0, -300, false, false), (false, 0, 0.01, false, false),
    (false, -500, 0, false, false), (false, 20, 300, true, false),
    (false, 100, 114, false, false), (false, 100, 116, false, false)
]
for (system, x, y, veto, wanted) in cases {
    expect(shouldBeginViewerInteractiveDismiss(willBegin: system, velocityX: x, velocityY: y, vetoed: veto) == wanted, "direction/veto regression")
}
var state = ViewerDismissInteraction()
let session = UUID()
var requests = ViewerPendingRequests<UUID>()
let b = UUID(), c = UUID()
requests.latest = b
expect(requests.take(phase: .dismissing(session), hasPresentedController: true) == nil && requests.latest == b, "B stays queued while A dismisses")
requests.latest = c
expect(requests.take(phase: .dismissing(session), hasPresentedController: false) == nil && requests.latest == c, "C replaces B without ending A")
expect(requests.take(phase: .empty, hasPresentedController: true) == nil && requests.latest == c, "completion cannot bypass UIKit ownership")
expect(requests.take(phase: .empty, hasPresentedController: false) == c, "only newest request opens after release")
expect(requests.take(phase: .empty, hasPresentedController: false) == nil, "request consumed exactly once")
for phase: ViewerPresentationPhase in [.empty, .presenting(session), .presented(session), .dismissing(session)] {
    for occupied in [false, true] {
        expect(mayPresentViewer(presentationPhase: phase, hasPresentedController: occupied) == (phase == .empty && !occupied), "presentation must be serialized")
    }
}
let first = state.begin()
expect(state.cancel(first), "first cancel")
let second = state.begin()
expect(second != first && state.active == second, "new drag replaces cancellation")
expect(!state.settle(first), "old completion must be ignored")
expect(!state.cancel(first), "old cancellation decision must be ignored")
expect(!state.commit(first), "old commit must be ignored")
expect(!state.settle(second), "appearance cannot settle an undecided drag")
expect(state.active == second, "new drag remains active")
expect(state.commit(second) && state.active == nil && state.cancelling == nil, "new drag commits")
let third = state.begin()
expect(state.cancel(third) && state.settle(third), "normal cancellation settles")
expect(state.active == nil && state.cancelling == nil && !state.settle(third), "settle is idempotent")
for _ in 0..<5 {
    let old = state.begin()
    expect(state.cancel(old), "repeat cancel")
    let new = state.begin()
    expect(!state.settle(old) && state.active == new, "repeat reentry isolates stale completion")
    expect(state.cancel(new) && state.settle(new), "repeat settle")
}
let pending = state.begin()
state.clear()
expect(!state.cancel(pending) && !state.commit(pending) && !state.settle(pending), "vanished session invalidates callbacks")
print("PASS: 12 veto cases, 8 presentation gates, pending/latest/exactly-once policy; stale callbacks, 5 reentries, cleanup")
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("photovault-dismiss-\(UUID().uuidString).swift")
defer { try? FileManager.default.removeItem(at: temp) }
try ("import Foundation\n" + source[start..<end] + tests).write(to: temp, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", temp.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
