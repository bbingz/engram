// macos/Engram/Views/Observability/PerformanceView.swift
import SwiftUI

struct PerformanceView: View {
    // OBS-C1: the Swift runtime emits no trace/metric rows (it logs only through
    // os_log, and does not record signpost intervals or aggregate metrics). The
    // old `metrics_hourly` / `traces` table reads were therefore always empty,
    // rendering a false "all clear". Until span/metric instrumentation exists,
    // this panel honestly reports that performance metrics are not collected
    // rather than fabricating an empty-but-healthy view.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "chart.line.uptrend.xyaxis", title: "Performance", badge: nil)
                EmptyState(
                    icon: "speedometer",
                    title: "Performance metrics not collected",
                    message: "The Engram runtime does not yet record span durations or aggregate metrics. Logs and errors are available in the other Observability tabs."
                )
                .accessibilityIdentifier("performance_notAvailable")
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_performance")
    }
}
