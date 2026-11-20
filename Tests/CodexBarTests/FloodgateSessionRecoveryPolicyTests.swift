import Foundation
import Testing
@testable import CodexBar

struct FloodgateSessionRecoveryPolicyTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `a lapse detected while the user is active prompts once`() {
        var policy = FloodgateSessionRecoveryPolicy()

        let first = policy.sessionLapsed(now: Self.start, screenLocked: false, idleSeconds: 5)
        let second = policy.sessionLapsed(now: Self.start.addingTimeInterval(600), screenLocked: false, idleSeconds: 5)

        #expect(first)
        #expect(!second)
    }

    @Test
    func `a lapse never prompts behind a locked screen or while the user is away`() {
        var locked = FloodgateSessionRecoveryPolicy()
        var away = FloodgateSessionRecoveryPolicy()

        let lockedPrompt = locked.sessionLapsed(now: Self.start, screenLocked: true, idleSeconds: 0)
        let awayPrompt = away.sessionLapsed(
            now: Self.start,
            screenLocked: false,
            idleSeconds: FloodgateSessionRecoveryPolicy.activeUserIdleLimit)

        #expect(!lockedPrompt)
        #expect(!awayPrompt)
    }

    @Test
    func `unlocking prompts even after the detection prompt was used`() {
        var policy = FloodgateSessionRecoveryPolicy()
        _ = policy.sessionLapsed(now: Self.start, screenLocked: false, idleSeconds: 5)

        let unlockPrompt = policy.userReturned(now: Self.start.addingTimeInterval(3600), screenLocked: false)

        #expect(unlockPrompt)
    }

    @Test
    func `unlock and wake firing together start a single prompt`() {
        var policy = FloodgateSessionRecoveryPolicy()

        let unlock = policy.userReturned(now: Self.start, screenLocked: false)
        let wake = policy.userReturned(now: Self.start.addingTimeInterval(2), screenLocked: false)

        #expect(unlock)
        #expect(!wake)
    }

    @Test
    func `a wake that lands on the lock screen waits for the unlock`() {
        var policy = FloodgateSessionRecoveryPolicy()

        let wakeOnLockScreen = policy.userReturned(now: Self.start, screenLocked: true)
        let unlock = policy.userReturned(now: Self.start.addingTimeInterval(1), screenLocked: false)

        #expect(!wakeOnLockScreen)
        #expect(unlock)
    }

    @Test
    func `recovery re-arms the detection prompt for the next lapse`() {
        var policy = FloodgateSessionRecoveryPolicy()
        _ = policy.sessionLapsed(now: Self.start, screenLocked: false, idleSeconds: 5)

        policy.sessionRecovered()
        let nextLapsePrompt = policy.sessionLapsed(
            now: Self.start.addingTimeInterval(7200),
            screenLocked: false,
            idleSeconds: 5)

        #expect(nextLapsePrompt)
    }

    @Test @MainActor
    func `floodgate registers a recovery runtime`() {
        #expect(FloodgateProviderImplementation().makeRuntime() is FloodgateProviderRuntime)
    }
}
