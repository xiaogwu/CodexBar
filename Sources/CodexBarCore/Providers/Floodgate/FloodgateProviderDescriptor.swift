import Foundation

public enum FloodgateProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    // D1: env vars first, config as fallback. `.environment` precedence plus `environmentHasValue`
    // means the config-projected value only lands in `context.env` when the real process
    // environment does not already define the key — the opposite of `.enterpriseHost`/
    // `.workspaceID`'s default `.config` precedence, which is why those convenience helpers are
    // not used here.
    private static let credentials = ProviderCredentialAdapter(
        environmentProjections: [
            ProviderCredentialEnvironmentProjection(
                key: FloodgateSettingsReader.hostEnvironmentKey,
                precedence: .environment,
                value: { $0.sanitizedEnterpriseHost },
                environmentHasValue: { $0[FloodgateSettingsReader.hostEnvironmentKey] != nil }),
            ProviderCredentialEnvironmentProjection(
                key: FloodgateSettingsReader.clientIDEnvironmentKey,
                precedence: .environment,
                value: { $0.sanitizedWorkspaceID },
                environmentHasValue: { $0[FloodgateSettingsReader.clientIDEnvironmentKey] != nil }),
        ])

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .floodgate,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .floodgate,
                displayName: "Floodgate",
                sessionLabel: "Budget",
                weeklyLabel: "Budget",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Floodgate usage",
                cliName: "appleconnect",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: nil,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .floodgate),
                iconResourceName: "ProviderIcon-floodgate",
                color: ProviderColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x2563EB),
                    ProviderColor(hex: 0x1E3A8A),
                    ProviderColor(hex: 0xBFDBFE),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Floodgate cost history is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [FloodgateFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "appleconnect",
                aliases: ["floodgate"],
                versionDetector: nil))
    }
}

struct FloodgateFetchStrategy: ProviderFetchStrategy {
    let id = "floodgate.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard FloodgateTokenResolver.isInstalled() else { return false }
        guard FloodgateSettingsReader.baseURL(environment: context.env) != nil else { return false }
        return FloodgateSettingsReader.clientID(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let baseURL = FloodgateSettingsReader.baseURL(environment: context.env),
              let clientID = FloodgateSettingsReader.clientID(environment: context.env)
        else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: "Floodgate needs a gateway host and OAuth client ID. Set " +
                    "\(FloodgateSettingsReader.hostEnvironmentKey)/\(FloodgateSettingsReader.clientIDEnvironmentKey) " +
                    "or configure them in Settings.")
        }

        let snapshot = try await Self.fetchUsage(
            baseURL: baseURL,
            clientID: clientID,
            environment: context.env,
            tokenResolver: FloodgateTokenResolver.shared,
            transport: FloodgateUsageFetcher.makeSession())
        return self.makeResult(usage: snapshot, sourceLabel: "appleconnect")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    /// D4: one forced refresh, one retry, on `.authenticationExpired`. Split out from `fetch`
    /// so tests can supply a stub token resolver and transport instead of a full
    /// `ProviderFetchContext`.
    ///
    /// A background tick can only clear CodexBar's own token cache, which does not help when the
    /// machine's AppleConnect session itself has lapsed — `getToken --interactivity-type=none`
    /// cannot re-establish one. A refresh the user actually clicked may therefore escalate to
    /// `--interactivity-type=gui`, letting `appleconnect` sign them back in on the spot. This
    /// mirrors `BrowserCookieAccessGate`, which gates its own prompt-capable work on the same
    /// ambient `ProviderInteractionContext`.
    static func fetchUsage(
        baseURL: URL,
        clientID: String,
        environment: [String: String],
        tokenResolver: FloodgateTokenResolver,
        transport: any ProviderHTTPTransport) async throws -> UsageSnapshot
    {
        do {
            let token = try await tokenResolver.token(clientID: clientID, environment: environment)
            return try await FloodgateUsageFetcher.fetchUsage(baseURL: baseURL, token: token, transport: transport)
        } catch let error as ProviderFetchClassifiedError where error.kind == .authenticationExpired {
            let token = try await tokenResolver.token(
                clientID: clientID,
                environment: environment,
                forceRefresh: true,
                interactivity: ProviderInteractionContext.current == .userInitiated ? .gui : .none)
            return try await FloodgateUsageFetcher.fetchUsage(baseURL: baseURL, token: token, transport: transport)
        }
    }
}
