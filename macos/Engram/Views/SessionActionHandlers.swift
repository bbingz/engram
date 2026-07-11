// macos/Engram/Views/SessionActionHandlers.swift
import AppKit
import SwiftUI

/// Export is a side-channel status so page content remains usable while the
/// service writes the transcript. One in-flight export is allowed per surface.
enum SessionExportState: Equatable {
    case idle
    case inFlight(sessionId: String)
    case succeeded(path: String)
    case failed(message: String)

    var isInFlight: Bool {
        if case .inFlight = self { return true }
        return false
    }

    var keepsResultsVisible: Bool { true }
    var allowsExportAction: Bool { !isInFlight }

    var statusText: String? {
        switch self {
        case .idle:
            nil
        case .inFlight:
            "Exporting…"
        case .succeeded(let path):
            "Exported to \((path as NSString).lastPathComponent)"
        case .failed(let message):
            message
        }
    }

    var revealPath: String? {
        if case .succeeded(let path) = self { return path }
        return nil
    }

    mutating func begin(sessionId: String) -> Bool {
        guard !isInFlight else { return false }
        self = .inFlight(sessionId: sessionId)
        return true
    }

    mutating func succeed(path: String) {
        self = .succeeded(path: path)
    }

    mutating func fail(message: String) {
        self = .failed(message: message)
    }

    mutating func clear() {
        self = .idle
    }
}

struct SessionExportStatusBanner: View {
    let state: SessionExportState

    var body: some View {
        if let status = state.statusText {
            HStack(spacing: 8) {
                if state.isInFlight {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("sessionExport_progress")
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle({
                        if case .failed = state { return Color.red }
                        return Color.secondary
                    }() as Color)
                Spacer(minLength: 4)
                if let path = state.revealPath {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("sessionExport_reveal")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
    }
}

/// Side-effecting session-action service calls shared by the browse pages
/// (SessionsPageView, TimelinePageView). It owns ONLY the service/clipboard/
/// Finder side effects — sheet-presentation state (resume/replay/rename targets)
/// stays as page @State.
@MainActor
struct SessionActionHandlers {
    let serviceClient: EngramServiceClient
    /// Reload the host page's list after a mutating command.
    let reload: () async -> Void
    /// Surface transient status/error text (rendered via AlertBanner).
    let onStatus: (String) -> Void

    /// Maps empty/whitespace-only input to nil (revert to auto title); else trims.
    nonisolated static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Copy the resume command (mirrors HomeView.copyResumeCommand).
    func copyResumeCommand(_ session: Session) {
        Task {
            do {
                let response = try await serviceClient.resumeCommand(sessionId: session.id)
                let item = try TodayResumeCommand.copyableClipboardItem(from: response)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
                onStatus(item.message)
            } catch {
                EngramLogger.error("SessionActions copy resume command failed", module: .ui, error: error)
                onStatus(String(localized: "Failed to copy resume command"))
            }
        }
    }

    /// Copy a handoff brief (mirrors SessionDetailView.performHandoff).
    func handoff(_ session: Session) {
        Task {
            do {
                let response = try await serviceClient.handoff(
                    EngramServiceHandoffRequest(
                        cwd: session.cwd,
                        sessionId: session.id,
                        format: "markdown"
                    )
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response.brief, forType: .string)
                onStatus("Handoff copied! (\(response.sessionCount) sessions)")
            } catch {
                onStatus("Handoff failed: \(error.localizedDescription)")
            }
        }
    }

    func setHidden(_ session: Session, hidden: Bool) {
        Task {
            do {
                try await serviceClient.setSessionHidden(sessionId: session.id, hidden: hidden)
                await reload()
            } catch {
                onStatus("\(hidden ? "Hide" : "Unhide") failed: \(error.localizedDescription)")
            }
        }
    }

    func rename(_ session: Session, to raw: String) {
        Task {
            do {
                try await serviceClient.renameSession(sessionId: session.id, name: Self.normalizedName(raw))
                await reload()
            } catch {
                onStatus("Rename failed")
            }
        }
    }

    func export(
        _ session: Session,
        format: String,
        completion: @escaping @MainActor (SessionExportState) -> Void
    ) {
        Task {
            do {
                let response = try await serviceClient.exportSession(
                    EngramServiceExportSessionRequest(id: session.id, format: format, outputHome: nil, actor: "app")
                )
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: response.outputPath)]
                )
                completion(.succeeded(path: response.outputPath))
            } catch {
                completion(.failed(message: "Export failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Write favorite membership, then reload list surfaces.
    /// - Parameter completion: Invoked on the main actor with `true` after a
    ///   successful service write + reload, or `false` on failure. Optional so
    ///   parent/Timeline call sites can ignore it; expanded child rows use it
    ///   to apply local `isFavorite` only after success.
    func setFavorite(
        _ session: Session,
        favorite: Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        Task {
            do {
                try await serviceClient.setFavorite(sessionId: session.id, favorite: favorite)
                onStatus(favorite ? "Added to favorites" : "Removed from favorites")
                // Reload so Browse flips labels and Starred drops removed rows.
                await reload()
                completion?(true)
            } catch {
                onStatus("Favorite failed: \(error.localizedDescription)")
                completion?(false)
            }
        }
    }

    /// Fire-and-forget access recording on open/resume.
    func recordAccess(_ session: Session) {
        Task {
            try? await serviceClient.recordSessionAccess(sessionId: session.id)
        }
    }
}
