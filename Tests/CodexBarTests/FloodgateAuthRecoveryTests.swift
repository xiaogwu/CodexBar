import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Serves a scripted status-code sequence, so a 401 followed by a 200 exercises the retry.
private actor RecoverySequenceTransport: ProviderHTTPTransport {
    private var statusCodes: [Int]
    private let body: Data

    init(statusCodes: [Int], body: Data) {
        self.statusCodes = statusCodes
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let statusCode = self.statusCodes.isEmpty ? 200 : self.statusCodes.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (self.body, response)
    }
}

/// Records the interactivity every `appleconnect` invocation asked for.
private actor InteractivityRecorder {
    private(set) var requested: [FloodgateTokenResolver.Interactivity] = []

    func record(_ interactivity: FloodgateTokenResolver.Interactivity) {
        self.requested.append(interactivity)
    }
}

struct FloodgateAuthRecoveryTests {
    private static func makeJWT(suffix: String) -> String {
        func encode(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        return "\(encode(#"{"alg":"none"}"#)).\(encode(#"{"exp":\#(exp)}"#)).sig-\(suffix)"
    }

    private static let usageBody = Data(#"""
    {
      "quota": {"budget": {"spend": 100.0, "reset_time": null}},
      "usage": {"spend": 10.0, "calls": 1, "input_tokens": 10, "output_tokens": 10}
    }
    """#.utf8)

    private static func fetchAfter401(
        interaction: ProviderInteraction) async throws -> [FloodgateTokenResolver.Interactivity]
    {
        let recorder = InteractivityRecorder()
        let resolver = FloodgateTokenResolver(runSubprocess: { _, _, interactivity in
            await recorder.record(interactivity)
            return #"{"oauth-id-token":"\#(Self.makeJWT(suffix: "t"))"}"#
        })
        let transport = RecoverySequenceTransport(statusCodes: [401, 200], body: Self.usageBody)

        _ = try await ProviderInteractionContext.$current.withValue(interaction) {
            try await FloodgateFetchStrategy.fetchUsage(
                baseURL: #require(URL(string: "https://gateway.example.com")),
                clientID: "test-client-id",
                environment: [:],
                tokenResolver: resolver,
                transport: transport)
        }
        return await recorder.requested
    }

    // MARK: - Interactive recovery

    @Test
    func `a refresh the user clicked escalates to an interactive appleconnect after a 401`() async throws {
        let requested = try await Self.fetchAfter401(interaction: .userInitiated)

        #expect(requested == [.none, .gui])
    }

    @Test
    func `a background tick never asks appleconnect for UI`() async throws {
        let requested = try await Self.fetchAfter401(interaction: .background)

        #expect(requested == [.none, .none])
    }

    @Test
    func `the ambient default is background so an unmarked fetch cannot prompt`() async throws {
        let recorder = InteractivityRecorder()
        let resolver = FloodgateTokenResolver(runSubprocess: { _, _, interactivity in
            await recorder.record(interactivity)
            return #"{"oauth-id-token":"\#(Self.makeJWT(suffix: "t"))"}"#
        })
        let transport = RecoverySequenceTransport(statusCodes: [401, 200], body: Self.usageBody)

        _ = try await FloodgateFetchStrategy.fetchUsage(
            baseURL: #require(URL(string: "https://gateway.example.com")),
            clientID: "test-client-id",
            environment: [:],
            tokenResolver: resolver,
            transport: transport)

        #expect(await recorder.requested == [.none, .none])
    }

    @Test
    func `a successful first fetch never spawns a second token mint`() async throws {
        let recorder = InteractivityRecorder()
        let resolver = FloodgateTokenResolver(runSubprocess: { _, _, interactivity in
            await recorder.record(interactivity)
            return #"{"oauth-id-token":"\#(Self.makeJWT(suffix: "t"))"}"#
        })
        let transport = RecoverySequenceTransport(statusCodes: [200], body: Self.usageBody)

        _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await FloodgateFetchStrategy.fetchUsage(
                baseURL: #require(URL(string: "https://gateway.example.com")),
                clientID: "test-client-id",
                environment: [:],
                tokenResolver: resolver,
                transport: transport)
        }

        #expect(await recorder.requested == [.none])
    }

    // MARK: - Snapshot preservation

    @Test
    func `floodgate auth expiry counts as recoverable so the last reading survives`() {
        let error = ProviderFetchClassifiedError(
            kind: .authenticationExpired,
            message: FloodgateUsageFetcher.authenticationExpiredMessage)

        #expect(UsageStore.isFloodgateRecoverableAuthFailure(provider: .floodgate, error))
        #expect(UsageStore.isFloodgateRecoverableAuthFailure(provider: .claude, error) == false)
    }

    @Test
    func `other floodgate failure kinds are not treated as recoverable`() {
        for kind in [
            ProviderFetchClassifiedError.Kind.permissionDenied,
            .parseFailure,
            .providerUnavailable,
            .missingCredential,
        ] {
            let error = ProviderFetchClassifiedError(kind: kind, message: "nope")
            #expect(UsageStore.isFloodgateRecoverableAuthFailure(provider: .floodgate, error) == false)
        }
    }

    // MARK: - Presentation

    @Test
    @MainActor
    func `a lapsed session is advisory and other floodgate failures are not`() {
        #expect(FloodgateUIErrorMapper.isSessionExpired(FloodgateUsageFetcher.authenticationExpiredMessage))
        #expect(FloodgateUIErrorMapper.isSessionExpired("Floodgate is unavailable.") == false)
        #expect(FloodgateUIErrorMapper.isSessionExpired(nil) == false)
    }

    @Test
    @MainActor
    func `an advisory error renders as ordinary secondary text instead of red`() {
        let advisory = UsageMenuCardView.Model.subtitleStyleForTesting(
            lastError: "AppleConnect session expired.",
            lastErrorIsAdvisory: true)
        let failure = UsageMenuCardView.Model.subtitleStyleForTesting(
            lastError: "Floodgate is unavailable.",
            lastErrorIsAdvisory: false)

        #expect(advisory == .info)
        #expect(failure == .error)
    }

    @Test
    @MainActor
    func `floodgate auth expiry reads as a session to re-authenticate with a stale capture age`() throws {
        let message = try #require(FloodgateUIErrorMapper.userFacingMessage(
            FloodgateUsageFetcher.authenticationExpiredMessage,
            staleSnapshotUpdatedAt: Date(timeIntervalSinceNow: -30 * 60),
            localize: { key in
                switch key {
                case "floodgate_appleconnect_session_expired": "localized session hint"
                case "floodgate_showing_last_known_usage": "stale capture %@"
                default: key
                }
            }))

        #expect(message.hasPrefix("localized session hint stale capture "))
    }

    @Test
    @MainActor
    func `unrecognized floodgate errors pass through unchanged`() {
        #expect(FloodgateUIErrorMapper.userFacingMessage(
            "Floodgate is unavailable.",
            staleSnapshotUpdatedAt: nil,
            localize: { $0 }) == "Floodgate is unavailable.")
        #expect(FloodgateUIErrorMapper.userFacingMessage(nil, staleSnapshotUpdatedAt: nil, localize: { $0 }) == nil)
        #expect(FloodgateUIErrorMapper.userFacingMessage("   ", staleSnapshotUpdatedAt: nil, localize: { $0 }) == nil)
    }

    @Test
    @MainActor
    func `the session hint tells the user refresh will sign them in`() {
        let hint = L("floodgate_appleconnect_session_expired")

        #expect(hint != "floodgate_appleconnect_session_expired")
        #expect(hint.contains("AppleConnect"))
        #expect(L("floodgate_showing_last_known_usage").contains("%@"))
    }
}
