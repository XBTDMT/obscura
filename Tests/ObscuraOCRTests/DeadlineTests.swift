import Testing
@testable import ObscuraOCR

@Suite struct DeadlineTests {
    @Test func neverReturningWorkTimesOut() async {
        var hit = false
        do {
            _ = try await Deadline.run(timeout: .milliseconds(50)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        } catch .timeout { hit = true } catch { }
        #expect(hit)
    }

    @Test func fastWorkWins() async throws {
        let value = try await Deadline.run(timeout: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func callerCancellationMapsToCancelled() async {
        let task = Task { () async throws -> Int in
            try await Deadline.run(timeout: .seconds(60)) { try await Task.sleep(for: .seconds(3600)); return 0 }
        }
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch OCRError.cancelled { cancelled = true } catch { }
        #expect(cancelled)
    }

    @Test func foreignErrorIsWrapped() async {
        struct Boom: Error {}
        var wrapped = false
        do { _ = try await Deadline.run(timeout: .seconds(5)) { () throws -> Int in throw Boom() } }
        catch .failed(let underlying) { wrapped = underlying is Boom } catch { }
        #expect(wrapped)
    }
}
