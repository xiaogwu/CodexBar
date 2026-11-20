import Foundation

/// Decides when Floodgate may recover a lapsed AppleConnect session without a click.
///
/// Renewing the session needs Touch ID. A prompted refresh (``FloodgateTokenResolver`` `.gui`) asks
/// for it, but only when the user is plausibly at the Mac: once when a lapse is first detected while
/// the screen is unlocked and in use, and again on unlock or wake.
struct FloodgateSessionRecoveryPolicy {
    /// Input older than this means nobody is at the Mac to answer a Touch ID prompt.
    static let activeUserIdleLimit: TimeInterval = 120
    /// Unlock and wake often fire together; one prompt covers both.
    static let promptDebounce: TimeInterval = 60

    private var promptedThisLapse = false
    private var lastPromptAt: Date?

    /// A refresh failed because the session lapsed. Returns true when this should start a prompt.
    mutating func sessionLapsed(now: Date, screenLocked: Bool, idleSeconds: TimeInterval) -> Bool {
        guard !self.promptedThisLapse, !screenLocked, idleSeconds < Self.activeUserIdleLimit else { return false }
        return self.claimPrompt(now: now)
    }

    /// A refresh succeeded. The next lapse may prompt again.
    mutating func sessionRecovered() {
        self.promptedThisLapse = false
    }

    /// The user unlocked or woke the Mac. Returns true when this should start a prompt.
    mutating func userReturned(now: Date, screenLocked: Bool) -> Bool {
        guard !screenLocked else { return false }
        return self.claimPrompt(now: now)
    }

    private mutating func claimPrompt(now: Date) -> Bool {
        if let lastPromptAt, now.timeIntervalSince(lastPromptAt) < Self.promptDebounce { return false }
        self.lastPromptAt = now
        self.promptedThisLapse = true
        return true
    }
}
