import Foundation

/// Response shape for `GET /api/usage/v1/personal` on the corporate gateway.
///
/// Field names verified against the reference implementation's `FloodgateAPIModels.swift`.
/// Model-level per-model quota/usage maps are out of scope for v1 and intentionally omitted —
/// this only decodes the keys it renders.
public struct FloodgateUsageResponse: Codable, Sendable {
    public let dsid: Int?
    public let quota: FloodgateQuota
    /// Present unless the gateway has no usage recorded yet for the account.
    public let usage: FloodgateUsage?

    public init(dsid: Int?, quota: FloodgateQuota, usage: FloodgateUsage?) {
        self.dsid = dsid
        self.quota = quota
        self.usage = usage
    }

    /// Maps the response into a `UsageSnapshot`, or `nil` when the gateway has no usage block to
    /// report. A missing `usage` block means "no data" — callers must throw `.parseFailure`
    /// rather than synthesize a `0%` window, which is how a phantom "0% used" would reach the
    /// menu bar for an account the gateway has not started reporting on yet.
    public func toUsageSnapshot(updatedAt: Date = Date()) -> UsageSnapshot? {
        guard let usage else { return nil }
        // `quota.budget.spend` is the LIMIT; `usage.spend` is the amount SPENT. The identical
        // field name across the two structs makes them easy to swap — do not conflate them.
        let limit = self.quota.budget.spend
        let spent = usage.spend
        let percent = limit > 0 ? (spent / limit) * 100 : 0
        let primary = RateWindow(
            usedPercent: percent,
            windowMinutes: nil,
            resetsAt: self.quota.budget.resetTime,
            resetDescription: nil)
        let rows: [ProviderDetailSection.Row] = [
            .makeRow(
                label: "Spend",
                value: UsageFormatter.usdString(spent),
                secondaryValue: "of \(UsageFormatter.usdString(limit))"),
            .makeRow(label: "Calls", value: "\(usage.calls)"),
            .makeRow(
                label: "Tokens",
                value: "In \(UsageFormatter.tokenCountString(usage.inputTokens)) · " +
                    "Out \(UsageFormatter.tokenCountString(usage.outputTokens))"),
        ]
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            details: [.makeSection(title: "Gateway usage", rows: rows)],
            updatedAt: updatedAt,
            identity: nil,
            dataConfidence: .exact)
    }
}

public struct FloodgateQuota: Codable, Sendable {
    public let budget: FloodgateBudget

    public init(budget: FloodgateBudget) {
        self.budget = budget
    }
}

public struct FloodgateBudget: Codable, Sendable {
    /// The spending LIMIT for the budget period, in USD.
    public let spend: Double
    public let resetTime: Date?

    public init(spend: Double, resetTime: Date?) {
        self.spend = spend
        self.resetTime = resetTime
    }

    private enum CodingKeys: String, CodingKey {
        case spend
        case resetTime = "reset_time"
    }
}

public struct FloodgateUsage: Codable, Sendable {
    /// The amount SPENT so far in the current budget period, in USD.
    public let spend: Double
    public let calls: Int
    public let inputTokens: Int
    public let outputTokens: Int

    public init(spend: Double, calls: Int, inputTokens: Int, outputTokens: Int) {
        self.spend = spend
        self.calls = calls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case spend
        case calls
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
