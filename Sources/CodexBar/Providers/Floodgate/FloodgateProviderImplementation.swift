import CodexBarCore
import Foundation

struct FloodgateProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .floodgate

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "appleconnect" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .floodgate, field: .endpoint]
        _ = settings[providerConfig: .floodgate, field: .workspace]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        guard FloodgateTokenResolver.isInstalled() else { return false }
        let hasHost = FloodgateSettingsReader.baseURL(environment: context.environment) != nil ||
            !context.settings[providerConfig: .floodgate, field: .endpoint]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasClientID = FloodgateSettingsReader.clientID(environment: context.environment) != nil ||
            !context.settings[providerConfig: .floodgate, field: .workspace]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasHost && hasClientID
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "floodgate-host",
                title: "Gateway host",
                subtitle: "Your internal gateway host. Stored in the CodexBar config file.",
                kind: .plain,
                placeholder: "gateway.example.com",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "floodgate-client-id",
                title: "OAuth client ID",
                subtitle: "Your internal gateway's OAuth client ID. Stored in the CodexBar config file.",
                kind: .plain,
                placeholder: "client-id",
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
