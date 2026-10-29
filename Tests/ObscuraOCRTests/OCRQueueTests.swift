import CoreGraphics
import Testing
@testable import ObscuraOCR

@Suite struct OCRQueueTests {
    @Test func clipboardJumpsAheadOfFiles() async throws {
        let recorder = CallRecorder()
        let gate = Gate()
        let queue = OCRQueue(recognizer: GatedRecognizer(gate: gate, recorder: recorder))
        let first = Task { try await queue.recognize(blankImage(width: 1), options: OCROptions(), priority: .file) }
        while await recorder.order.isEmpty { await Task.yield() }
        let f2 = Task { try await queue.recognize(blankImage(width: 2), options: OCROptions(), priority: .file) }
        while await queue.depth < 2 { await Task.yield() }
        let f3 = Task { try await queue.recognize(blankImage(width: 3), options: OCROptions(), priority: .file) }
        while await queue.depth < 3 { await Task.yield() }
        let c4 = Task { try await queue.recognize(blankImage(width: 4), options: OCROptions(), priority: .clipboard) }
        while await queue.depth < 4 { await Task.yield() }
        #expect(await queue.depth == 4)
        await gate.release()
        _ = try await (first.value, f2.value, f3.value, c4.value)
        #expect(await recorder.order == ["w1", "w4", "w2", "w3"])
        #expect(await queue.depth == 0)
    }

    @Test func oneRecognitionAtATime() async throws {
        let recorder = CallRecorder()
        let queue = OCRQueue(recognizer: RecordingRecognizer(recorder: recorder, delay: .milliseconds(20)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 1...6 {
                group.addTask { _ = try await queue.recognize(blankImage(width: w), options: OCROptions(), priority: .file) }
            }
            try await group.waitForAll()
        }
        #expect(await recorder.maxConcurrent == 1)
        #expect(await recorder.order.count == 6)
    }

    @Test func fullQueueEvictsOldestFile() async throws {
        let recorder = CallRecorder()
        let gate = Gate()
        let queue = OCRQueue(recognizer: GatedRecognizer(gate: gate, recorder: recorder), maxQueued: 1)
        let running = Task { try await queue.recognize(blankImage(width: 1), options: OCROptions(), priority: .file) }
        while await recorder.order.isEmpty { await Task.yield() }
        let waiting = Task { try await queue.recognize(blankImage(width: 2), options: OCROptions(), priority: .file) }
        while await queue.depth < 2 { await Task.yield() }
        let newcomer = Task { try await queue.recognize(blankImage(width: 3), options: OCROptions(), priority: .file) }
        var evicted = false
        do { _ = try await waiting.value } catch OCRError.queueFull { evicted = true }
        #expect(evicted)
        await gate.release()
        _ = try await running.value
        _ = try await newcomer.value
        #expect(await recorder.order == ["w1", "w3"])
    }

    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let recorder = CallRecorder()
        let gate = Gate()
        let queue = OCRQueue(recognizer: GatedRecognizer(gate: gate, recorder: recorder))
        let running = Task { try await queue.recognize(blankImage(width: 1), options: OCROptions(), priority: .file) }
        while await recorder.order.isEmpty { await Task.yield() }
        let waiting = Task { try await queue.recognize(blankImage(width: 2), options: OCROptions(), priority: .file) }
        while await queue.depth < 2 { await Task.yield() }
        waiting.cancel()
        var cancelled = false
        do { _ = try await waiting.value } catch OCRError.cancelled { cancelled = true }
        #expect(cancelled)
        while await queue.depth > 1 { await Task.yield() }
        await gate.release()
        _ = try await running.value
        #expect(await recorder.order == ["w1"])
    }
}
