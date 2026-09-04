import Foundation
import XCTest

@testable import TelemetryKit

final class PipelinePerformanceTests: XCTestCase {
    func testPrivacySanitizationPerformance() {
        let filter = TelemetryPrivacyFilter(configuration: TelemetryPrivacyConfiguration())
        let events = (0..<2_000).map { index in
            TelemetryEvent(
                name: "screen.rendered.\(index)",
                attributes: [
                    "screen": .string("checkout"),
                    "duration_ms": .double(Double(index) / 10),
                    "successful": .boolean(index.isMultiple(of: 2)),
                    "items": .array((0..<8).map { .integer(Int64($0)) }),
                    "token": .string("must-never-survive"),
                ]
            )
        }

        measure {
            var sanitizedCount = 0
            for event in events where filter.sanitize(event) != nil {
                sanitizedCount += 1
            }
            XCTAssertEqual(sanitizedCount, events.count)
        }
    }

    func testEventEncodingPerformance() {
        let encoder = JSONEncoder()
        let events = (0..<2_000).map { index in
            TelemetryEvent(
                name: "benchmark.event",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                attributes: [
                    "index": .integer(Int64(index)),
                    "message": .string(String(repeating: "x", count: 128)),
                    "context": .object([
                        "cold_start": .boolean(false),
                        "sample_rate": .double(0.25),
                    ]),
                ]
            )
        }

        measure {
            var encodedBytes = 0
            for event in events {
                encodedBytes += (try? encoder.encode(event).count) ?? 0
            }
            XCTAssertGreaterThan(encodedBytes, 0)
        }
    }

    func testBoundedIngressBurstPerformance() {
        let limits = TelemetryQueueLimits(
            maximumMemoryEventCount: 500,
            maximumMemoryBytes: 64 * 1_024,
            maximumEventCount: 10_000,
            maximumDiskBytes: 20 * 1_024 * 1_024,
            maximumEventBytes: 1_024,
            maximumEventAge: 3_600,
            overflowPolicy: .dropNewest
        )
        let payload = Data(repeating: 0xAB, count: 128)

        measure {
            let buffer = IngressBuffer(
                limits: limits,
                enabledCategories: [.custom],
                consent: .granted
            )
            for _ in 0..<20_000 {
                _ = buffer.offer(
                    PendingEvent(
                        id: UUID(),
                        createdAt: Date(),
                        category: .custom,
                        payload: payload
                    )
                )
            }
            let status = buffer.status()
            XCTAssertEqual(status.eventCount, 500)
            XCTAssertEqual(status.byteCount, 500 * payload.count)
        }
    }

    func testBatchEncodingPerformance() {
        let events = (0..<50).map { index in
            TelemetryEvent(
                name: "batch.event",
                attributes: [
                    "index": .integer(Int64(index)),
                    "payload": .string(String(repeating: "p", count: 512)),
                ]
            )
        }
        let encoder = JSONEncoder()

        measure {
            var encodedBytes = 0
            for _ in 0..<100 {
                let batch = TelemetryUploadBatch(events: events)
                encodedBytes += (try? encoder.encode(batch).count) ?? 0
            }
            XCTAssertGreaterThan(encodedBytes, 0)
        }
    }
}
