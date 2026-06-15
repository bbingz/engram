// macos/Engram/Views/Pages/ObservabilityView.swift
import SwiftUI

struct ObservabilityView: View {
    enum Tab: String, CaseIterable {
        case logs = "Logs"
        case errors = "Errors"
        case performance = "Performance"
        case traces = "Traces"
        case health = "Health"
    }

    @State private var selectedTab: Tab = .logs
    // observability-6: gate the whole developer-diagnostics surface behind a
    // default-off flag. The sidebar item (SidebarView) hides the entry on the
    // common path; this in-view gate is the safety net if Observability is
    // reached another way. The Settings toggle that flips this flag is added by
    // a later Settings WP.
    @AppStorage("showDeveloperTools") private var showDeveloperTools = false

    var body: some View {
        Group {
            if showDeveloperTools {
                tabbedContent
            } else {
                EmptyState(
                    icon: "wrench.and.screwdriver",
                    title: "Developer diagnostics hidden",
                    message: "Observability shows internal logs and health. Enable Settings > General > Show Developer Tools to view it."
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("observability_container")
    }

    private var tabbedContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                        .accessibilityIdentifier("observability_tab_\(tab.rawValue.lowercased())")
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("observability_tabPicker")

            switch selectedTab {
            case .logs:
                LogStreamView()
            case .errors:
                ErrorDashboardView()
            case .performance:
                PerformanceView()
            case .traces:
                TraceExplorerView()
            case .health:
                SystemHealthView()
            }
        }
    }
}
