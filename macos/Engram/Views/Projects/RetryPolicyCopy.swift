// macos/Engram/Views/Projects/RetryPolicyCopy.swift
//
// Human-readable translations for the `retry_policy` enum returned by the
// TS orchestrator. The Swift UI used to print the raw enum value
// ("retry_policy: wait") which confused users — Gemini major #5.
//
// Values mirror the server:
//   'safe'        — the operation is retry-idempotent; a clean retry works
//   'conditional' — transient (e.g. concurrent write); re-read state first
//   'wait'        — another move is in progress (lock held); retry later
//   'never'       — requires user intervention (user typed a bad path,
//                   the target dir exists, etc.)

import Foundation

/// Friendly explainer shown under the error message. Omitted entirely
/// for 'never' (the error message itself already says what to fix).
func retryPolicyExplainer(_ policy: String) -> String {
    switch policy {
    case "safe":
        return "This usually clears itself — retrying is safe."
    case "conditional":
        return "A concurrent write changed the file. Retry to let us re-scan."
    case "wait":
        return "Another project move is in progress. Retry in a moment."
    case "never":
        return "This can't auto-retry — resolve the cause above, then try again."
    default:
        return ""
    }
}

/// True when the UI should offer a Retry button. 'never' suppresses it
/// because the same action would hit the same error.
func retryPolicyAllowsRetry(_ policy: String) -> Bool {
    policy == "safe" || policy == "conditional" || policy == "wait"
}
