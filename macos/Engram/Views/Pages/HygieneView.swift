// macos/Engram/Views/Pages/HygieneView.swift
import SwiftUI

// MARK: - Main View

struct HygieneView: View {
    @Environment(EngramServiceClient.self) private var serviceClient
    @State private var result: EngramServiceHygieneResponse? = nil
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var error: String? = nil
    @State private var errorsExpanded = true
    @State private var warningsExpanded = true
    @State private var infoExpanded = false
    @State private var pendingHideConfirm = false
    @State private var resultToast: String? = nil

    private var errorIssues: [EngramServiceHygieneIssue] {
        result?.issues.filter { $0.severity == "error" } ?? []
    }
    private var warningIssues: [EngramServiceHygieneIssue] {
        result?.issues.filter { $0.severity == "warning" } ?? []
    }
    private var infoIssues: [EngramServiceHygieneIssue] {
        result?.issues.filter { $0.severity == "info" } ?? []
    }

    private var emptySessionsIssue: EngramServiceHygieneIssue? {
        result?.issues.first { $0.kind == "empty-sessions" }
    }

    /// Count to show in the confirmation dialog/button — re-derived from the
    /// empty-sessions issue message (the service carries the count there).
    private var pendingHideCount: Int {
        emptySessionsIssue.map { Self.emptySessionCount(in: $0) } ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kpiSection
                explainerCaption
                headerBar
                if let resultToast {
                    Text(resultToast)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                        .accessibilityIdentifier("hygiene_resultToast")
                }
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
        .confirmationDialog(
            "Hide empty sessions?",
            isPresented: $pendingHideConfirm,
            titleVisibility: .visible
        ) {
            Button("Hide \(pendingHideCount) session(s)", role: .destructive) {
                Task { await hideEmptySessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These sessions have no messages and clutter search results. Hidden sessions are not deleted — view them again under Sessions → Show hidden sessions.")
        }
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

    // MARK: - Explainer

    private var explainerCaption: some View {
        Text("Hiding sets sessions aside (kept under Sessions → Show hidden sessions); tiering (skip/lite) controls what gets indexed and searched.")
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("hygiene_explainer")
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
                isExpanded: $errorsExpanded,
                onHideEmptySessions: requestHideEmptySessions
            )
            .accessibilityIdentifier("hygiene_section_errors")
        }
        if !warningIssues.isEmpty {
            IssueSection(
                title: "Warnings",
                count: warningIssues.count,
                severity: "warning",
                issues: warningIssues,
                isExpanded: $warningsExpanded,
                onHideEmptySessions: requestHideEmptySessions
            )
            .accessibilityIdentifier("hygiene_section_warnings")
        }
        if !infoIssues.isEmpty {
            IssueSection(
                title: "Info",
                count: infoIssues.count,
                severity: "info",
                issues: infoIssues,
                isExpanded: $infoExpanded,
                onHideEmptySessions: requestHideEmptySessions
            )
            .accessibilityIdentifier("hygiene_section_info")
        }
    }

    // MARK: - Remediation

    private func requestHideEmptySessions() {
        resultToast = nil
        pendingHideConfirm = true
    }

    private func hideEmptySessions() async {
        error = nil
        do {
            let response = try await serviceClient.hideEmptySessions()
            resultToast = Self.hideResultToast(hiddenCount: response.hiddenCount)
            await loadData(force: true)
        } catch {
            self.error = "Could not hide empty sessions: \(error.localizedDescription)"
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
            result = try await serviceClient.hygiene(force: force)
        } catch {
            self.error = "Could not load hygiene data: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Re-derives the empty-session count from the service issue message
    /// (e.g. "12 empty session(s) clutter the index" → 12). The service does
    /// not carry a structured count field, so we parse the leading integer.
    static func emptySessionCount(in issue: EngramServiceHygieneIssue) -> Int {
        let prefix = issue.message.prefix { $0.isNumber }
        return Int(prefix) ?? 0
    }

    /// Reversibility-aware toast shown after a successful hide.
    static func hideResultToast(hiddenCount: Int) -> String {
        "Hid \(hiddenCount) session(s) — view them under Sessions → Show hidden sessions"
    }

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
    let issues: [EngramServiceHygieneIssue]
    @Binding var isExpanded: Bool
    let onHideEmptySessions: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                MotionAware.animate(.easeInOut(duration: 0.2), reduceMotion: reduceMotion) {
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
                    IssueCard(
                        issue: issue,
                        onHideEmptySessions: issue.kind == "empty-sessions" ? onHideEmptySessions : nil
                    )
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
    let issue: EngramServiceHygieneIssue
    var onHideEmptySessions: (() -> Void)? = nil

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

            // In-app remediation (empty-sessions only)
            if let onHideEmptySessions {
                Button {
                    onHideEmptySessions()
                } label: {
                    Text("Hide empty sessions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(severityColor)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hygiene_hideEmptyButton")
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
