import CodexBarCore
import Foundation

extension UsageStore {
    /// A Floodgate 401 is a lapsed SSO session, not lost data. Keep the last-good reading on
    /// screen while the session comes back instead of blanking the provider.
    nonisolated static func isFloodgateRecoverableAuthFailure(
        provider: UsageProvider,
        _ error: Error) -> Bool
    {
        // Provider-specific by design: only Floodgate's auth depends on an external SSO session
        // that refreshes without CodexBar's involvement.
        guard provider == .floodgate else { return false }
        guard let classified = error as? ProviderFetchClassifiedError else { return false }
        return classified.kind == .authenticationExpired
    }

    /// True when the provider's current error is advisory — something the user resolves outside
    /// CodexBar, not a CodexBar malfunction. Advisory errors render in the ordinary secondary
    /// color instead of red, so a lapsed AppleConnect session reads as a prompt to sign in rather
    /// than as a broken app.
    func userFacingErrorIsAdvisory(for provider: UsageProvider) -> Bool {
        // Provider-specific by design: Floodgate is the only provider whose auth lives in an
        // external SSO session the user re-establishes themselves.
        guard provider == .floodgate else { return false }
        return FloodgateUIErrorMapper.isSessionExpired(self.errors[provider.instanceID])
    }
}
