---
summary: "Floodgate corporate-gateway spend and budget through a locally minted AppleConnect OIDC token."
read_when:
  - Configuring Floodgate
  - Debugging Floodgate usage or token errors
---

# Floodgate

- Opt-in, CLI-gated corporate gateway provider (`defaultEnabled: false`, not widget-selectable). Nothing is probed or shown until an internal gateway host and OAuth client ID are configured — there is no default for either.
- Configure the gateway host and OAuth client ID in Settings → Providers → Floodgate, or via `CODEXBAR_FLOODGATE_HOST` / `CODEXBAR_FLOODGATE_CLIENT_ID`. Both are stored in the CodexBar config file; env vars take precedence over the config values.
- Requires the locally installed `appleconnect` CLI to mint a short-lived OIDC bearer token (`appleconnect getToken --interactivity-type=none`, never interactive, never a GUI prompt). No browser cookies and no Keychain reads are involved.
- Reads `/api/usage/v1/personal` for spend against the account's budget, request count, and input/output token totals; the reset time comes from the gateway's own budget-period boundary.
- The token is cached in memory and refreshed automatically before it expires; a token rejected by the gateway (HTTP 401) triggers exactly one forced refresh and retry.
