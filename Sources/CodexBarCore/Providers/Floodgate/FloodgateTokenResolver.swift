import Foundation

public enum FloodgateTokenError: LocalizedError, Sendable, Equatable {
    case appleconnectNotInstalled
    case tokenNotFound

    public var errorDescription: String? {
        switch self {
        case .appleconnectNotInstalled:
            "appleconnect is not installed at \(FloodgateTokenResolver.binaryPath)."
        case .tokenNotFound:
            "appleconnect did not return a usable token."
        }
    }
}

/// Mints and caches the OIDC bearer token the corporate gateway expects, by shelling out to the
/// locally installed `appleconnect` CLI.
///
/// AppleConnect returns both an OAuth access token and an OIDC ID token. The gateway requires
/// the ID token; never select a token based on dictionary iteration order. Unknown output shapes
/// are accepted only when they contain one unambiguous JWT. Token values are never logged.
public actor FloodgateTokenResolver {
    /// Runs `appleconnect` and returns its raw stdout. Injectable so tests can supply a fake
    /// token mint without shelling out to a CLI that may not be installed on the test machine.
    public typealias SubprocessRunning = @Sendable (
        _ clientID: String,
        _ environment: [String: String],
        _ interactivity: Interactivity) async throws -> String

    /// Whether `appleconnect` may put UI on screen to re-establish a lapsed SSO session.
    ///
    /// Background refresh ticks must stay ``none``: an unattended tick that pops an AppleConnect
    /// window (or a Touch ID sheet behind it) is exactly the surprise ``FloodgateURLSessionDelegate``
    /// exists to prevent. ``gui`` is reserved for a refresh the user asked for by clicking.
    public enum Interactivity: String, Sendable {
        case none
        case gui
    }

    public static let shared = FloodgateTokenResolver()
    static let binaryPath = "/usr/local/bin/appleconnect"
    private static let refreshMargin: TimeInterval = 300
    private static let assumedLifetime: TimeInterval = 3600
    private static let log = CodexBarLog.logger(LogCategories.provider(.floodgate))

    private var cached: (token: String, expiry: Date)?
    private let runSubprocess: SubprocessRunning

    public init(runSubprocess: @escaping SubprocessRunning = FloodgateTokenResolver.runAppleconnect) {
        self.runSubprocess = runSubprocess
    }

    public static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: self.binaryPath)
    }

    public static func runAppleconnect(
        clientID: String,
        environment: [String: String],
        interactivity: Interactivity = .none) async throws -> String
    {
        guard self.isInstalled() else {
            throw FloodgateTokenError.appleconnectNotInstalled
        }
        let result = try await SubprocessRunner.run(
            binary: Self.binaryPath,
            arguments: [
                "getToken",
                "--token-type=oauth",
                "-C", clientID,
                "-G", "pkce",
                "-o", "openid,dsid,accountname,profile,groups",
                "--interactivity-type=\(interactivity.rawValue)",
                "-E", "prod",
                "-O", "json",
            ],
            environment: environment,
            timeout: 20,
            label: "floodgate-appleconnect-token")
        return result.stdout
    }

    public func token(
        clientID: String,
        environment: [String: String],
        forceRefresh: Bool = false,
        interactivity: Interactivity = .none,
        now: Date = Date()) async throws -> String
    {
        if !forceRefresh, let cached, cached.expiry.timeIntervalSince(now) > Self.refreshMargin {
            return cached.token
        }

        let stdout = try await self.runSubprocess(clientID, environment, interactivity)
        guard let token = Self.extractToken(from: stdout) else {
            Self.log.warning("Floodgate token extraction failed", metadata: ["label": "floodgate-appleconnect-token"])
            throw FloodgateTokenError.tokenNotFound
        }
        let expiry = Self.expiry(ofJWT: token) ?? now.addingTimeInterval(Self.assumedLifetime)
        self.cached = (token: token, expiry: expiry)
        Self.log.debug("Floodgate token refreshed", metadata: ["label": "floodgate-appleconnect-token"])
        return token
    }

    /// Prefers AppleConnect's named OIDC ID token, including nested JSON responses. For legacy
    /// output shapes, accepts a single unambiguous JWT or the final token in plain-text output.
    static func extractToken(from stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data)
        {
            let idTokens = self.tokenCandidates(in: json, idTokensOnly: true)
            let candidates = Set(idTokens.isEmpty ? self.tokenCandidates(in: json) : idTokens)
            guard candidates.count == 1, let token = candidates.first, self.isJWT(token) else { return nil }
            return token
        }

        if let lastToken = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .last
            .map(String.init),
            self.isJWT(lastToken)
        {
            return lastToken
        }
        return nil
    }

    private static func tokenCandidates(in value: Any, idTokensOnly: Bool = false) -> [String] {
        switch value {
        case let string as String:
            !idTokensOnly && self.isJWT(string) ? [string] : []
        case let array as [Any]:
            array.flatMap { self.tokenCandidates(in: $0, idTokensOnly: idTokensOnly) }
        case let dictionary as [String: Any]:
            dictionary.flatMap { key, value in
                if idTokensOnly, ["oauth-id-token", "id_token", "idToken"].contains(key) {
                    // An explicitly malformed ID token must not fall back to an access token.
                    return [value as? String ?? ""]
                }
                if ["oauth-access-token", "access_token", "accessToken"].contains(key) { return [] }
                return self.tokenCandidates(in: value, idTokensOnly: idTokensOnly)
            }
        default:
            []
        }
    }

    private static func isJWT(_ candidate: String) -> Bool {
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        return self.decodedJWTPayload(fromMiddleSegment: String(segments[1])) != nil
    }

    private static func expiry(ofJWT token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = self.decodedJWTPayload(fromMiddleSegment: String(segments[1])),
              let exp = payload["exp"] as? NSNumber
        else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func decodedJWTPayload(fromMiddleSegment segment: String) -> [String: Any]? {
        guard let data = self.base64URLDecode(segment) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json.keys.contains("exp") ? json : nil
    }

    private static func base64URLDecode(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
