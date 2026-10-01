import Foundation
import Testing

@testable import MatrixKit

/// Counts `PersistCoalescer` write executions.
private actor WriteCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("PersistCoalescer")
struct PersistCoalescerTests {
    @Test("bursts collapse into one write")
    func burstsCoalesce() async throws {
        let counter = WriteCounter()
        let coalescer = PersistCoalescer(interval: .milliseconds(50)) {
            await counter.increment()
        }
        await coalescer.markDirty()
        await coalescer.markDirty()
        await coalescer.markDirty()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await counter.count == 1)
    }

    @Test("flush writes immediately without waiting out the interval")
    func flushWritesNow() async throws {
        let counter = WriteCounter()
        let coalescer = PersistCoalescer(interval: .seconds(30)) {
            await counter.increment()
        }
        await coalescer.markDirty()
        await coalescer.flush()
        #expect(await counter.count == 1)
        // The scheduled flush was consumed: nothing more arrives.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await counter.count == 1)
    }

    @Test("cancel suppresses the scheduled write")
    func cancelSuppresses() async throws {
        let counter = WriteCounter()
        let coalescer = PersistCoalescer(interval: .milliseconds(50)) {
            await counter.increment()
        }
        await coalescer.markDirty()
        await coalescer.cancel()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await counter.count == 0)
    }
}
