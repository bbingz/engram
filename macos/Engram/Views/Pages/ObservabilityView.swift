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

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

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
