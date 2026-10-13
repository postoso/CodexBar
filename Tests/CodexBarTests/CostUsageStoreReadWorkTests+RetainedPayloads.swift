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
        #expect(!fixture.save(cache).catchUpRequired)
        let persisted = await fixture.store.readSnapshot()
        #expect(persisted.metadata.previousReportPayload != nil)
        #expect(persisted.metadata.priorityTurnStatePayload != nil)

        let roots = CostUsageScanner.codexSessionsRoots(options: fixture.options)
        let fingerprint = CostUsageScanner.codexRootsFingerprint(options: fixture.options)
        for purpose in [CostUsageStoreReadPurpose.status, .activity] {
            let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
            let cold = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: purpose)
            let retained = try #require(await reader.retainedCodexRead)
            #expect(retained.purpose == purpose)
            // Both payloads are decoded into the retained cache; the raw bytes have no reader.
            #expect(retained.persistence.metadata.previousReportPayload == nil)
            #expect(retained.persistence.metadata.priorityTurnStatePayload == nil)
            #expect(retained.decoded.codexPreviousReport == previousReport)

            let warm = reader.syncLoadCodexReadView(calendar: fixture.calendar, purpose: purpose)
            let status = warm.catchUpStatus(roots: roots, rootsFingerprint: fingerprint)
            #expect(status.pending)
            #expect(status.staleSnapshotUpdatedAt == fixture.now.addingTimeInterval(-60))
            #expect(status == cold.catchUpStatus(roots: roots, rootsFingerprint: fingerprint))
            #expect(warm.previousReport(range: fixture.range, rootsFingerprint: fingerprint)
                == cold.previousReport(range: fixture.range, rootsFingerprint: fingerprint))
            #expect(warm.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot).data
                == cold.dailyReport(range: fixture.range, cacheRoot: fixture.env.cacheRoot).data)
        }
        #expect(await fixture.store.readSnapshot() == persisted)
    }
}
