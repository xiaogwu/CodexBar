import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Declines TLS client-certificate challenges.
///
/// The gateway advertises an *optional* TLS `CertificateRequest`, and all real authentication
/// rides on the Bearer OIDC token. With no delegate, CFNetwork answers a client-certificate
/// challenge with its default identity-selection behavior: it walks the keychain, finds the
/// AppleConnect identity, and asks the Secure Enclave to sign the handshake — a Touch ID prompt
/// on every refresh tick. `.useCredential` with a `nil` credential sends a zero-length
/// certificate list, which a non-mandatory `CertificateRequest` accepts, so the handshake
/// completes anonymously.
///
/// Do NOT use `.cancelAuthenticationChallenge`: it cancels the request (-999) and every fetch
/// fails. Every other challenge — server trust above all — falls through to
/// `.performDefaultHandling` so genuine server-certificate failures still surface normally.
final class FloodgateURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

public enum FloodgateUsageFetcher {
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: FloodgateURLSessionDelegate(), delegateQueue: nil)
    }

    public static func fetchUsage(
        baseURL: URL,
        token: String,
        transport: any ProviderHTTPTransport = FloodgateUsageFetcher.makeSession()) async throws -> UsageSnapshot
    {
        let url = FloodgateSettingsReader.personalUsageURL(baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar/\(self.appVersion())", forHTTPHeaderField: "User-Agent")

        let response = try await transport.response(for: request)
        try self.checkStatus(response)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(FloodgateUsageResponse.self, from: response.data) else {
            throw ProviderFetchClassifiedError(kind: .parseFailure, message: "Floodgate response could not be parsed.")
        }
        guard let snapshot = decoded.toUsageSnapshot() else {
            throw ProviderFetchClassifiedError(kind: .parseFailure, message: "Floodgate response has no usage data.")
        }
        return snapshot
    }

    private static func checkStatus(_ response: ProviderHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ProviderFetchClassifiedError(kind: .authenticationExpired, message: "Floodgate token expired.")
        case 403:
            throw ProviderFetchClassifiedError(kind: .permissionDenied, message: "Floodgate access denied.")
        case 429:
            throw ProviderFetchClassifiedError(
                kind: .rateLimited,
                message: "Floodgate rate limited the request.",
                retryAfterSeconds: self.retryAfterSeconds(response))
        case 500..<600:
            throw ProviderFetchClassifiedError(kind: .providerUnavailable, message: "Floodgate is unavailable.")
        default:
            throw ProviderFetchClassifiedError(
                kind: .apiFailure,
                message: "Floodgate returned HTTP \(response.statusCode).")
        }
    }

    private static func retryAfterSeconds(_ response: ProviderHTTPResponse) -> TimeInterval? {
        guard let header = response.response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(header.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return seconds
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
