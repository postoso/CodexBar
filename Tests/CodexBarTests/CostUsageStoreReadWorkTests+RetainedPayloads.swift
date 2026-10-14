import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `warm status and activity read views drop raw metadata payloads but keep their decoded state`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        var cache = fixture.canonical
        var previousCache = cache
        previousCache.lastScanUnixMs -= 60000
        let previousReport = CostUsageCodexPreviousReport(
            report: fixture.fullReport(cache),
            cache: previousCache,
            reportSinceKey: fixture.range.sinceKey,
            reportUntilKey: fixture.range.untilKey)
        cache.codexPreviousReport = previousReport
        let turn = CostUsageScanner.CodexPriorityTurnMetadata(
            threadID: "fixture-thread", turnID: "fixture-turn", model: "gpt-5.4", timestamp: "2026-08-01T12:00:00Z")
        cache.codexPriorityTurnKeys = [ReadWorkFixture.day: "fixture-priority-key"]
        cache.codexPriorityTurnIDsByDay = [ReadWorkFixture.day: ["fixture-turn"]]
        cache.codexResolvedPriorityTurns = ["fixture-turn": turn]
        cache.codexPriorityTurnsCursor = .init(
            databasePath: fixture.env.root.appendingPathComponent("synthetic-trace.sqlite").path,
            coverageSinceEpoch: 1_785_542_400,
            lastRowID: 7,
            fileIdentity: 42,
            anchorRowID: 7,
            anchorDigest: "fixture-digest",
            anchors: [.init(rowID: 7, digest: "fixture-digest")],
            turns: ["fixture-turn": turn],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: ["fixture-turn"],
            completedTurnIDInsertionOrderStartIndex: 0)
        #expect(!fixture.save(cache).catchUpRequired)
        let persisted = await fixture.store.readSnapshot()
        #expect(persisted.metadata.previousReportPayload != nil)
        #expect(persisted.metadata.priorityTurnStatePayload != nil)

        let roots = CostUsageScanner.codexSessionsRoots(options: fixture.options)
        let fingerprint = CostUsageScanner.codexRootsFingerprint(options: fixture.options)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var recordingHooks = CostUsageStoreTestHooks.current
        recordingHooks.readWorkRecorder = recorder
        try await CostUsageStoreTestHooks.$current.withValue(recordingHooks) {
            for purpose in [CostUsageStoreReadPurpose.status, .activity] {
                let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
                let conversions = recorder.snapshot().cacheConversions
                let cold = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: purpose)
                #expect(recorder.snapshot().cacheConversions == conversions + 1)
                let retained = try #require(await reader.retainedCodexRead)
                #expect(retained.purpose == purpose)
                // Both payloads are decoded into the retained cache; the raw bytes have no reader.
                #expect(retained.persistence.metadata.previousReportPayload == nil)
                #expect(retained.persistence.metadata.priorityTurnStatePayload == nil)
                #expect(retained.decoded.codexPreviousReport == previousReport)
                #expect(retained.decoded.codexPriorityTurnKeys == cache.codexPriorityTurnKeys)
                #expect(retained.decoded.codexPriorityTurnIDsByDay == cache.codexPriorityTurnIDsByDay)
                #expect(retained.decoded.codexResolvedPriorityTurns == cache.codexResolvedPriorityTurns)
                #expect(retained.decoded.codexPriorityTurnsCursor == cache.codexPriorityTurnsCursor)

                // The warm read reuses the retained state instead of decoding the snapshot again.
                let warm = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: purpose)
                #expect(recorder.snapshot().cacheConversions == conversions + 1)
                let status = warm.catchUpStatus(roots: roots, rootsFingerprint: fingerprint)
                #expect(status.pending)
                #expect(status.staleSnapshotUpdatedAt == fixture.now.addingTimeInterval(-60))
                #expect(status == cold.catchUpStatus(roots: roots, rootsFingerprint: fingerprint))
                #expect(warm.previousReport(range: fixture.range, rootsFingerprint: fingerprint)
                    == cold.previousReport(range: fixture.range, rootsFingerprint: fingerprint))
                #expect(warm.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot).data
                    == cold.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot).data)
            }

            // Escalating one store from status to activity to report decodes intact metadata for the report.
            let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
            _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .status)
            _ = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .activity)
            let report = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: .report)
            #expect(report.previousReport(range: fixture.range, rootsFingerprint: fingerprint) == previousReport)
            #expect(await reader.retainedCodexRead?.purpose == .activity)
        }
        #expect(await fixture.store.readSnapshot() == persisted)
    }
}
