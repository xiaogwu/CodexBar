import AppKit
import CodexBarCore
import CoreGraphics
import Foundation

/// Recovers Floodgate from a lapsed AppleConnect session without waiting for a menu click.
///
/// Prompted refreshes run under `.userInitiated`, which lets ``FloodgateFetchStrategy`` escalate
/// `appleconnect` to `--interactivity-type=gui` (Touch ID). ``FloodgateSessionRecoveryPolicy``
/// decides when that is allowed.
@MainActor
final class FloodgateProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .floodgate
    private static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    /// Lets the network come back after a wake before the prompted refresh hits the gateway.
    private static let userReturnedDelay: Duration = .seconds(3)

    private var policy = FloodgateSessionRecoveryPolicy()
    private var store: UsageStore?
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var promptTask: Task<Void, Never>?

    nonisolated init() {}

    func start(context: ProviderRuntimeContext) {
        self.store = context.store
        guard self.observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let onReturn: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.userReturned() }
        }
        self.observers = [
            (distributed, distributed.addObserver(
                forName: Self.screenUnlockedNotification, object: nil, queue: .main, using: onReturn)),
            (workspace, workspace.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onReturn)),
        ]
    }

    func stop(context _: ProviderRuntimeContext) {
        for observer in self.observers {
            observer.center.removeObserver(observer.token)
        }
        self.observers = []
        self.promptTask?.cancel()
        self.promptTask = nil
        self.policy = FloodgateSessionRecoveryPolicy()
        self.store = nil
    }

    func providerDidRefresh(context _: ProviderRuntimeContext, provider: UsageProvider) {
        guard provider == .floodgate else { return }
        self.policy.sessionRecovered()
    }

    func providerDidFail(context: ProviderRuntimeContext, provider: UsageProvider, error: Error) {
        guard provider == .floodgate,
              UsageStore.isFloodgateRecoverableAuthFailure(provider: provider, error)
        else { return }
        self.store = context.store
        let shouldPrompt = self.policy.sessionLapsed(
            now: Date(),
            screenLocked: Self.isScreenLocked(),
            idleSeconds: Self.idleSeconds())
        if shouldPrompt {
            self.startPromptedRefresh(after: .zero)
        }
    }

    private func userReturned() {
        guard let store = self.store, store.isEnabled(.floodgate) else { return }
        // Refresh even when no lapse is known yet: the timer may not have run while the Mac slept.
        // The prompted refresh tries a silent mint first and only shows Touch ID if that fails.
        guard self.policy.userReturned(now: Date(), screenLocked: Self.isScreenLocked()) else { return }
        self.startPromptedRefresh(after: Self.userReturnedDelay)
    }

    private func startPromptedRefresh(after delay: Duration) {
        guard self.promptTask == nil else { return }
        self.promptTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            defer { self.promptTask = nil }
            guard let store = self.store, store.isEnabled(.floodgate) else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await store.refreshProvider(.floodgate)
            }
        }
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
