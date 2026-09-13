import CodexBarCore
import Foundation

@MainActor
enum FloodgateUIErrorMapper {
    /// True when this raw error is the gateway rejecting a lapsed AppleConnect session.
    static func isSessionExpired(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) == FloodgateUsageFetcher
            .authenticationExpiredMessage
    }

    /// Rewrites Floodgate's raw fetch errors for the menu. A rejected token reads like a CodexBar
    /// bug; it is an AppleConnect SSO session that lapsed (typically overnight) and returns once
    /// the machine re-authenticates, so the message says who needs to act and that CodexBar keeps
    /// retrying. Appends the age of the reading still on screen, the way Claude's mapper does.
    static func userFacingMessage(
        _ raw: String?,
        staleSnapshotUpdatedAt: Date?,
        localize: (String) -> String = L) -> String?
    {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let message = if trimmed == FloodgateUsageFetcher.authenticationExpiredMessage {
            localize("floodgate_appleconnect_session_expired")
        } else {
            trimmed
        }
        guard let staleSnapshotUpdatedAt else { return message }
        return message + " " + String(
            format: localize("floodgate_showing_last_known_usage"),
            staleSnapshotUpdatedAt.relativeDescription())
    }
}
