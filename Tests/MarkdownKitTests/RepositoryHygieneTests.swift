import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RepositoryHygieneTests {
    /// No test may wait on a timer.
    ///
    /// A sleep in a test is a bet that the work finishes first, and the bet has
    /// to be sized for the slowest machine that will ever run it — the wait this
    /// suite replaced carried a measured 121.5 s legitimate stall. Every wait
    /// here is instead driven by a `RenderObservationPoint` or an `EventSignal`,
    /// so it ends when the work does. A condition that becomes true with no
    /// report hangs, and each suite's `.timeLimit` is what turns that into a
    /// failure.
    ///
    /// The Example app keeps one deliberate sleep: it paces a simulated token
    /// stream for a person to watch, which is a real delay rather than a guess
    /// about one.
    @Test func noTestWaitsOnATimer() throws {
        // Split so this test does not match itself.
        let forbidden = "Task" + ".sleep"
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            if try String(contentsOf: url, encoding: .utf8).contains(forbidden) {
                offenders.append(url.lastPathComponent)
            }
        }
        // Guards against the walk silently finding nothing — an empty scan would
        // make this test pass for the wrong reason after any layout change.
        #expect(scanned > 40, "only \(scanned) test sources found under \(root.path)")
        #expect(offenders.isEmpty, "\(forbidden) in \(offenders.sorted().joined(separator: ", "))")
    }
}
