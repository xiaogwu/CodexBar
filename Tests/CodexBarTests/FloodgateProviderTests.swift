import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct FloodgateProviderTests {
    @Test
    func `floodgate response maps spend and reset into the primary window`() throws {
        let body = #"""
        {
          "dsid": 12345,
          "quota": {
            "budget": {
              "spend": 300.0,
              "reset_time": "2026-09-10T00:00:00Z"
            }
          },
          "usage": {
            "spend": 150.85,
            "calls": 42,
            "input_tokens": 1200000,
            "output_tokens": 340000
          }
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FloodgateUsageResponse.self, from: Data(body.utf8))
        let snapshot = decoded.toUsageSnapshot(updatedAt: Date(timeIntervalSince1970: 0))

        let expectedPercent = 150.85 / 300.0 * 100
        #expect(snapshot != nil)
        #expect(snapshot?.primary.map { abs($0.usedPercent - expectedPercent) < 1e-9 } == true)
        #expect(snapshot?.primary?.resetsAt != nil)
        let rows = snapshot?.details.first?.rows ?? []
        #expect(rows.count == 3)
        #expect(rows[0].label == "Spend")
        #expect(rows[1].label == "Calls")
        #expect(rows[2].label == "Tokens")
    }

    @Test
    func `missing usage block does not synthesize a zero percent window`() throws {
        let body = #"""
        {
          "quota": {
            "budget": {
              "spend": 300.0,
              "reset_time": null
            }
          }
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FloodgateUsageResponse.self, from: Data(body.utf8))
        #expect(decoded.toUsageSnapshot() == nil)
    }

    @Test
    func `appleconnect token extraction accepts json and plain output`() {
        // Fabricated JWT for tests only — header/payload/signature are all made up, never a real token.
        let futureExp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let header = Self.base64URLEncode(#"{"alg":"none"}"#)
        let payload = Self.base64URLEncode(#"{"exp":\#(futureExp),"sub":"test"}"#)
        let fakeJWT = "\(header).\(payload).fakesignature"

        let jsonBlob = #"{"result":{"oauth-id-token":"\#(fakeJWT)","other":"value"}}"#
        #expect(FloodgateTokenResolver.extractToken(from: jsonBlob) == fakeJWT)

        let plainOutput = "Some banner text\nAuthenticated successfully\n\(fakeJWT)"
        #expect(FloodgateTokenResolver.extractToken(from: plainOutput) == fakeJWT)

        #expect(FloodgateTokenResolver.extractToken(from: "") == nil)
        #expect(FloodgateTokenResolver.extractToken(from: "not a token at all") == nil)
    }

    @Test
    func `expired token triggers one forced refresh`() async throws {
        let futureExp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let header = Self.base64URLEncode(#"{"alg":"none"}"#)
        let payload = Self.base64URLEncode(#"{"exp":\#(futureExp)}"#)

        let tokenCallCount = TestCounter()
        let resolver = FloodgateTokenResolver(runSubprocess: { _, _, _ in
            await tokenCallCount.increment()
            let fakeJWT = await "\(header).\(payload).sig-\(tokenCallCount.value())"
            return #"{"oauth-id-token":"\#(fakeJWT)"}"#
        })

        let body = #"""
        {
          "quota": {"budget": {"spend": 100.0, "reset_time": null}},
          "usage": {"spend": 10.0, "calls": 1, "input_tokens": 10, "output_tokens": 10}
        }
        """#
        let transport = FloodgateSequenceTransport(statusCodes: [401, 200], body: Data(body.utf8))

        let snapshot = try await FloodgateFetchStrategy.fetchUsage(
            baseURL: #require(URL(string: "https://gateway.example.com")),
            clientID: "test-client-id",
            environment: [:],
            tokenResolver: resolver,
            transport: transport)

        #expect(await transport.requestCount == 2)
        #expect(await tokenCallCount.value() == 2)
        #expect(snapshot.primary?.usedPercent == 10)
    }

    @Test
    func `client certificate challenges are declined without a credential`() async {
        let delegate = FloodgateURLSessionDelegate()
        let challenge = Self.makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate)

        let (disposition, credential) = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        #expect(disposition == .useCredential)
        #expect(credential == nil)
        #expect(disposition != .cancelAuthenticationChallenge)
        #expect(disposition != .performDefaultHandling)
    }

    @Test
    func `server trust challenges fall through to default handling`() async {
        let delegate = FloodgateURLSessionDelegate()
        let challenge = Self.makeChallenge(authenticationMethod: NSURLAuthenticationMethodServerTrust)

        let (disposition, credential) = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
                continuation.resume(returning: (disposition, credential))
            }
        }

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test
    func `strategy is unavailable without host or client id`() async throws {
        let strategy = FloodgateFetchStrategy()
        let context = Self.makeContext(env: [:])

        #expect(await strategy.isAvailable(context) == false)

        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected missingCredential")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        }
    }

    @Test
    func `strategy is available once host and client id are set`() async {
        let strategy = FloodgateFetchStrategy()
        let context = Self.makeContext(env: [
            FloodgateSettingsReader.hostEnvironmentKey: "gateway.example.com",
            FloodgateSettingsReader.clientIDEnvironmentKey: "test-client-id",
        ])
        // Without the appleconnect binary installed on the test machine, availability still
        // requires FloodgateTokenResolver.isInstalled(), so this only proves the host/client-id
        // gate, not the CLI gate, unless appleconnect happens to be present.
        let available = await strategy.isAvailable(context)
        #expect(available == FloodgateTokenResolver.isInstalled())
    }

    // MARK: - Helpers

    private static func makeChallenge(authenticationMethod: String) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "gateway.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: authenticationMethod)
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoOpChallengeSender())
    }

    private static func makeContext(env: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func base64URLEncode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private final class NoOpChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
        func cancel(_: URLAuthenticationChallenge) {}
    }
}

private actor TestCounter {
    private var count = 0

    func increment() {
        self.count += 1
    }

    func value() -> Int {
        self.count
    }
}

private actor FloodgateSequenceTransport: ProviderHTTPTransport {
    private var statusCodes: [Int]
    private let body: Data
    private(set) var requestCount = 0

    init(statusCodes: [Int], body: Data) {
        self.statusCodes = statusCodes
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestCount += 1
        let statusCode = self.statusCodes.isEmpty ? 200 : self.statusCodes.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (self.body, response)
    }
}
