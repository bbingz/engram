// macos/EngramCoreWrite/ProjectMove/Paths.swift
// Mirrors src/core/project-move/paths.ts (Node parity baseline).
//
// Pure `~`/`~/` expansion only — does not resolve relative paths. Centralized
// so MCP / CLI / batch boundaries apply the same rule.
import Foundation
import EngramCoreRead

public enum ProjectPath {
    /// Expand a leading `~` or `~/...` to the user's home directory. Empty
    /// strings and paths without a leading tilde pass through unchanged.
    public static func expandHome(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        ProjectReviewPathSupport.expandHome(path, homeDirectory: homeDirectory)
    }
}
