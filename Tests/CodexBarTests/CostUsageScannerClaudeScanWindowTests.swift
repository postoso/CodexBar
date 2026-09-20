import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageScannerClaudeScanWindowTests {
    @Test
    func `alternating narrow and wide windows reuse parsed transcripts`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let today = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let old = try self.day(today, offset: -100)
        let recent = try self.writeEvent(env: env, day: today, path: "project/recent.jsonl", id: "recent", input: 10)
        _ = try self.writeEvent(env: env, day: old, path: "project/old.jsonl", id: "old", input: 7)
        let options = self.options(env: env)
        let wideSince = try self.day(today, offset: -364)
        let narrowSince = try self.day(today, offset: -29)

        let (wide, cold) = self.recordedLoad(since: wideSince, now: today, options: options)
        #expect(cold.transcriptParses == 2)
        #expect(wide.data.count == 2)

        // A live transcript grows between refreshes, so the narrow caller rewrites the shared cache.
        try self.append(env: env, to: recent, day: today, id: "appended", input: 5)
        let (narrow, narrowWork) = self.recordedLoad(since: narrowSince, now: today, options: options)
        #expect(narrowWork.transcriptParses == 1)
        #expect(narrowWork.incrementalTranscriptParses == 1)
        #expect(narrow.data.count == 1)

        let (wideAgain, wideWork) = self.recordedLoad(since: wideSince, now: today, options: options)
        #expect(wideWork.transcriptParses == 0)
        #expect(wideAgain.data.count == 2)
        #expect(wideAgain.data.first == wide.data.first)
    }

    @Test
    func `next local day extends the window without reparsing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let today = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let tomorrow = try self.day(today, offset: 1)
        let file = try self.writeEvent(env: env, day: today, path: "project/session.jsonl", id: "first", input: 10)
        let options = self.options(env: env)
        let since = try self.day(today, offset: -29)
        let rolledSince = try self.day(tomorrow, offset: -29)
        _ = self.recordedLoad(since: since, now: today, options: options)

        let (rolled, rolledWork) = self.recordedLoad(since: rolledSince, now: tomorrow, options: options)
        #expect(rolledWork.transcriptParses == 0)
        #expect(rolled.data.count == 1)

        try self.append(env: env, to: file, day: tomorrow, id: "second", input: 5)

        let (appended, appendWork) = self.recordedLoad(since: rolledSince, now: tomorrow, options: options)
        #expect(appendWork.transcriptParses == 1)
        #expect(appendWork.incrementalTranscriptParses == 1)
        #expect(appended.data.count == 2)
    }

    @Test
    func `earlier start still rescans to recover filtered rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let today = try env.makeLocalNoon(year: 2026, month: 7, day: 1)
        let old = try self.day(today, offset: -100)
        _ = try self.writeEvent(env: env, day: today, path: "project/recent.jsonl", id: "recent", input: 10)
        _ = try self.writeEvent(env: env, day: old, path: "project/old.jsonl", id: "old", input: 7)
        let options = self.options(env: env)

        let (narrow, _) = try self.recordedLoad(since: self.day(today, offset: -29), now: today, options: options)
        #expect(narrow.data.count == 1)

        let (wide, wideWork) = try self.recordedLoad(since: self.day(today, offset: -364), now: today, options: options)
        #expect(wideWork.transcriptParses == 2)
        #expect(wide.data.count == 2)
    }

    private func day(_ date: Date, offset: Int) throws -> Date {
        try #require(Calendar.current.date(byAdding: .day, value: offset, to: date))
    }

    private func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: .current)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private func recordedLoad(
        since: Date,
        now: Date,
        options: CostUsageScanner.Options) -> (CostUsageDailyReport, CostUsageScanner.ClaudeScanWorkMetrics)
    {
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        let report = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            CostUsageScanner.loadDailyReport(
                provider: .claude,
                since: since,
                until: now,
                now: now,
                options: options)
        }
        return (report, recorder.snapshot())
    }

    private func writeEvent(
        env: CostUsageTestEnvironment,
        day: Date,
        path: String,
        id: String,
        input: Int) throws -> URL
    {
        try env.writeClaudeProjectFile(
            relativePath: path,
            contents: env.jsonl([self.event(env: env, day: day, id: id, input: input)]))
    }

    private func append(env: CostUsageTestEnvironment, to file: URL, day: Date, id: String, input: Int) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([self.event(env: env, day: day, id: id, input: input)]).utf8))
    }

    private func event(env: CostUsageTestEnvironment, day: Date, id: String, input: Int) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": env.isoString(for: day),
            "sessionId": "session-\(id)",
            "requestId": "request-\(id)",
            "message": [
                "id": "message-\(id)",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
        ]
    }
}
