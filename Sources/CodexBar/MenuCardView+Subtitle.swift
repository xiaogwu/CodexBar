import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    /// A card subtitle's error together with whether it is advisory. Advisory conditions are the
    /// user's to resolve elsewhere (a lapsed SSO session), so they read as ordinary secondary text.
    struct SubtitleError {
        let message: String?
        let isAdvisory: Bool
    }

    static func subtitle(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        lastError: SubtitleError,
        hasLastKnownUsage: Bool,
        now: Date) -> (text: String, style: SubtitleStyle)
    {
        if let message = lastError.message, !message.isEmpty {
            let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only genuine failures go red.
            return (message, lastError.isAdvisory ? .info : .error)
        }

        if isRefreshing {
            return ("\(L("Refreshing"))…", .loading)
        }

        if hasLastKnownUsage {
            return ("", .info)
        }

        if let updated = snapshot?.updatedAt {
            return (UsageFormatter.updatedString(from: updated, now: now), .info)
        }

        return (L("Not fetched yet"), .info)
    }
}

#if DEBUG
extension UsageMenuCardView.Model {
    /// Exposes only the subtitle's chosen style, so tests can assert that advisory conditions stay
    /// out of the red failure styling without assembling a whole card `Input`.
    static func subtitleStyleForTesting(lastError: String?, lastErrorIsAdvisory: Bool) -> SubtitleStyle {
        self.subtitle(
            snapshot: nil,
            isRefreshing: false,
            lastError: SubtitleError(message: lastError, isAdvisory: lastErrorIsAdvisory),
            hasLastKnownUsage: false,
            now: Date()).style
    }
}
#endif
