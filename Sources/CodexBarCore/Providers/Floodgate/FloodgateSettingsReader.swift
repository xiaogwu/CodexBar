import Foundation

/// Resolves the corporate gateway host and OAuth client ID for the Floodgate provider.
///
/// Per D1, neither value ships with a default: this is an Apple-internal gateway, and the
/// diff for this provider must not carry an internal hostname or IdMS app identifier. Both
/// values are read, in order, from the two environment keys below and then from the matching
/// `ProviderConfig` fields (`enterpriseHost`, `workspaceID`). The config fallback happens
/// automatically before a fetch strategy ever sees `environment`: `FloodgateProviderDescriptor`
/// registers `.enterpriseHost`/`.workspaceID` environment projections (the same mechanism
/// `Wayfinder` and `ClawRouter` use) so `ProviderEnvironmentResolver.resolve` merges the config
/// values into the environment dictionary a strategy receives, with a real process environment
/// variable always winning over the config value. Callers here only ever need `environment`.
public enum FloodgateSettingsReader {
    public static let hostEnvironmentKey = "CODEXBAR_FLOODGATE_HOST"
    public static let clientIDEnvironmentKey = "CODEXBAR_FLOODGATE_CLIENT_ID"

    /// Base URL for the gateway, e.g. `https://<host>`. No default: an unconfigured install has
    /// no provider.
    public static func baseURL(environment: [String: String]) -> URL? {
        guard let raw = self.cleaned(environment[self.hostEnvironmentKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }

    public static func clientID(environment: [String: String]) -> String? {
        self.cleaned(environment[self.clientIDEnvironmentKey])
    }

    /// The `/api/usage/v1/personal` endpoint under the configured base URL. Nothing else in v1.
    public static func personalUsageURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("api/usage/v1/personal")
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
