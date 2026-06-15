// macos/Engram/Views/SessionActionHandlers.swift
import AppKit
import SwiftUI

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

    func export(_ session: Session, format: String) {
        Task {
            do {
                let response = try await serviceClient.exportSession(
                    EngramServiceExportSessionRequest(id: session.id, format: format, outputHome: nil, actor: "app")
                )
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: response.outputPath)]
                )
                onStatus("Exported to \((response.outputPath as NSString).lastPathComponent)")
            } catch {
                onStatus("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func setFavorite(_ session: Session, favorite: Bool) {
        Task {
            do {
                try await serviceClient.setFavorite(sessionId: session.id, favorite: favorite)
                onStatus(favorite ? "Added to favorites" : "Removed from favorites")
            } catch {
                onStatus("Favorite failed: \(error.localizedDescription)")
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
