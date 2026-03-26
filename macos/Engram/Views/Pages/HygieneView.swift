// macos/Engram/Views/Pages/HygieneView.swift
import SwiftUI

// MARK: - Data Models

struct HygieneIssue: Codable, Identifiable {
    var id: String { "\(kind)-\(message.prefix(40))" }
    let kind: String
    let severity: String
    let message: String
    let detail: String?
    let repo: String?
    let action: String?
}

struct HygieneCheckResult: Codable {
    let issues: [HygieneIssue]
    let score: Int
    let checkedAt: String
}

// MARK: - Main View

struct HygieneView: View {
    @Environment(DaemonClient.self) private var daemon
    @State private var result: HygieneCheckResult? = nil
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var error: String? = nil
    @State private var errorsExpanded = true
    @State private var warningsExpanded = true
    @State private var infoExpanded = false

    private var errorIssues: [HygieneIssue] {
        result?.issues.filter { $0.severity == "error" } ?? []
    }
    private var warningIssues: [HygieneIssue] {
        result?.issues.filter { $0.severity == "warning" } ?? []
    }
    private var infoIssues: [HygieneIssue] {
        result?.issues.filter { $0.severity == "info" } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kpiSection
                headerBar
                if let error {
                    AlertBanner(message: error)
                }
                if isLoading {
                    skeletonSection
                } else if let result, result.issues.isEmpty {
                    emptyState
                } else {
                    issuesSection
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("hygiene_container")
        .task { await loadData(force: false) }
    }

    // MARK: - KPI Section

    @ViewBuilder
    private var kpiSection: some View {
        if let result {
            HStack(spacing: 12) {
                KPICard(value: "\(result.score)", label: "Score")
                    .accessibilityIdentifier("hygiene_kpi_score")
                KPICard(value: "\(errorIssues.count)", label: "Errors")
                    .accessibilityIdentifier("hygiene_kpi_errors")
                KPICard(value: "\(warningIssues.count)", label: "Warnings")
                    .accessibilityIdentifier("hygiene_kpi_warnings")
                KPICard(value: "\(infoIssues.count)", label: "Info")
                    .accessibilityIdentifier("hygiene_kpi_info")
            }
            .accessibilityIdentifier("hygiene_kpiCards")
        } else {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            if let result {
                Text("Last checked: \(formatRelativeTime(result.checkedAt))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button {
                Task { await loadData(force: true) }
            } label: {
                HStack(spacing: 4) {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    Text("Refresh")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(isRefreshing)
            .accessibilityIdentifier("hygiene_refreshButton")
        }
    }

    // MARK: - Skeleton

    private var skeletonSection: some View {
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.border)
                    .frame(height: 72)
                    .opacity(0.5)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All clean!")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.primaryText)
            Text("No hygiene issues found.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityIdentifier("hygiene_emptyState")
    }

    // MARK: - Issues Section

    @ViewBuilder
    private var issuesSection: some View {
        if !errorIssues.isEmpty {
            IssueSection(
                title: "Errors",
                count: errorIssues.count,
                severity: "error",
                issues: errorIssues,
                isExpanded: $errorsExpanded
            )
            .accessibilityIdentifier("hygiene_section_errors")
        }
        if !warningIssues.isEmpty {
            IssueSection(
                title: "Warnings",
                count: warningIssues.count,
                severity: "warning",
                issues: warningIssues,
                isExpanded: $warningsExpanded
            )
            .accessibilityIdentifier("hygiene_section_warnings")
        }
        if !infoIssues.isEmpty {
            IssueSection(
                title: "Info",
                count: infoIssues.count,
                severity: "info",
                issues: infoIssues,
                isExpanded: $infoExpanded
            )
            .accessibilityIdentifier("hygiene_section_info")
        }
    }

    // MARK: - Data Loading

    private func loadData(force: Bool) async {
        if force {
            isRefreshing = true
        } else {
            isLoading = true
        }
        error = nil
        defer {
            isLoading = false
            isRefreshing = false
        }
        do {
            result = try await daemon.fetchHygieneChecks(force: force)
        } catch {
            self.error = "Could not load hygiene data: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func formatRelativeTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return iso }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

// MARK: - IssueSection

private struct IssueSection: View {
    let title: String
    let count: Int
    let severity: String
    let issues: [HygieneIssue]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 12)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(severityColor(severity))
                        .clipShape(Capsule())
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(issues) { issue in
                    IssueCard(issue: issue)
                }
            }
        }
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "error":   return .red
        case "warning": return .orange
        default:        return .blue
        }
    }
}

// MARK: - IssueCard

private struct IssueCard: View {
    let issue: HygieneIssue
    @State private var copied = false

    private var severityColor: Color {
        switch issue.severity {
        case "error":   return .red
        case "warning": return .orange
        default:        return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kind badge + repo
            HStack(spacing: 6) {
                Text(issue.kind)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(severityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if let repo = issue.repo, !repo.isEmpty {
                    Text(repo)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
            }

            // Message
            Text(issue.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Detail (optional)
            if let detail = issue.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action suggestion with copy button
            if let action = issue.action, !action.isEmpty {
                HStack(spacing: 6) {
                    Text("💡")
                        .font(.system(size: 11))
                    Text(action)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(action, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Text(copied ? "Copied!" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? .green : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hygiene_copy_\(issue.kind)")
                }
                .padding(8)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
