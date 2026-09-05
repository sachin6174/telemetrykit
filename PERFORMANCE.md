# Performance evidence

The suite measures privacy filtering, event/batch encoding, bounded ingress,
and the public capture path under sustained queue saturation. It asserts logical
queue limits and records time, CPU, and physical-memory metrics. An XCTest pass
without an approved baseline is not a latency or memory-budget guarantee.

## Reproduce

```sh
swift test -c release --filter PipelinePerformanceTests
```

Run on an otherwise idle, representative device or host with sanitizers and code
coverage disabled. Keep the toolchain, configuration, thermal conditions, and
payload shape consistent. Save full samples, not just the fastest observation.

The sanitizer lane runs the saturation workload and assertions without the
CPU/memory measurement wrapper. On the tested Xcode 26.6/iOS 26.5 combination,
XCTest crashes in `measureWithMetrics` under Thread Sanitizer; a minimal probe
containing only `XCTAssertEqual(2 + 2, 4)` reproduced the crash without SDK
operations. `validate-package.sh` sets `TELEMETRYKIT_SANITIZER` for that lane.
This does not disable sanitizer instrumentation or skip the saturation test.

## Initial observations — 2026-09-05

Apple M1 MacBook Air, 8 GB RAM, macOS 26.6.2, Xcode 26.6 / Swift 6.3.3.
These exploratory runs shared the host with simulator validation and are not
approved regression thresholds.

The saturation case prefills 500 events, disables background consumers, then
submits 20,000 public captures per measured iteration. All subsequent captures
must return `queueFull`; event count stays at 500 and serialized queue bytes stay
within the configured 1 MiB limit. A five-iteration standalone run measured:

| Metric | Observation |
| --- | --- |
| Wall time per 20,000 submissions | 0.685 s mean, 23.3% relative standard deviation |
| CPU time per 20,000 submissions | 0.412 s mean, 6.0% relative standard deviation |
| Physical-memory delta per iteration | 180.224, 16.384, 16.384, 0, 0 kB |
| Process physical-memory peak | 12.323–12.372 MB |

Memory metrics cover the XCTest process, not exclusively TelemetryKit. Full-suite
runs have a different starting footprint and may show negative deltas when the
allocator releases earlier allocations. The observed plateau is useful evidence,
but does not prove an absolute RSS bound under every payload or OS condition.

Before production rollout, measure accepted-event throughput as well as rejection
cost, disk recovery at maximum capacity, sustained delivery, energy impact, and
end-to-end latency on the oldest supported iPhone. Establish reviewed thresholds
there; do not copy these Mac observations into mobile production budgets.
