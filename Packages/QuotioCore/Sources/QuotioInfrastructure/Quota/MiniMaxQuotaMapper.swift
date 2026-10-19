import Foundation
import QuotioDomain

/// Maps a MiniMax Token Plan `/token_plan/remains` response to the five-hour interval and
/// the weekly window of the general (text) model entitlement.
enum MiniMaxQuotaMapper {
  static let fiveHourMetric = "minimax-five-hour"
  static let weeklyMetric = "minimax-weekly"
  /// `base_resp.status_code` values MiniMax uses for a rejected or non-plan key.
  static let authenticationFailureCodes: Set<Int> = [1004, 2049]

  /// The non-zero `base_resp.status_code`, if the response carries one.
  static func statusCode(_ data: Data) -> Int? {
    guard let base = CodingPlanJSON.object(CodingPlanJSON.object(data)?["base_resp"]),
      let code = CodingPlanJSON.number(base["status_code"]), code != 0
    else { return nil }
    return Int(code)
  }

  static func map(_ data: Data, now: Date) -> ProviderQuota? {
    guard let json = CodingPlanJSON.object(data), statusCode(data) == nil else { return nil }
    let root = CodingPlanJSON.object(json["data"]) ?? json
    guard let entries = root["model_remains"] as? [Any] else { return nil }
    let objects = entries.compactMap { $0 as? [String: Any] }
    let name: ([String: Any]) -> String? = {
      CodingPlanJSON.string($0, keys: ["model_name"])?.lowercased()
    }
    guard
      let entry = objects.first(where: { name($0) == "general" })
        ?? objects.first(where: { name($0) != "video" }) ?? objects.first
    else { return nil }

    let metrics = [
      metric(
        name: fiveHourMetric, entry: entry,
        totalKey: "current_interval_total_count", usedKey: "current_interval_usage_count",
        percentKey: "current_interval_remaining_percent",
        endKey: "end_time", remainsKey: "remains_time", now: now),
      metric(
        name: weeklyMetric, entry: entry,
        totalKey: "current_weekly_total_count", usedKey: "current_weekly_usage_count",
        percentKey: "current_weekly_remaining_percent",
        endKey: "weekly_end_time", remainsKey: "weekly_remains_time", now: now),
    ].compactMap { $0 }
    guard !metrics.isEmpty else { return nil }
    let plan =
      CodingPlanJSON.string(
        root, keys: ["current_subscribe_title", "plan_name", "plan", "subscription_plan"])
      ?? "Token Plan"
    return ProviderQuota(models: metrics, lastUpdated: now, planType: plan)
  }

  private static func metric(
    name: String,
    entry: [String: Any],
    totalKey: String,
    usedKey: String,
    percentKey: String,
    endKey: String,
    remainsKey: String,
    now: Date
  ) -> QuotaMetric? {
    let limit = CodingPlanJSON.number(entry[totalKey])
    let used = CodingPlanJSON.number(entry[usedKey])
    let remainingPercent: Double?
    if let limit, limit > 0, let used {
      remainingPercent = (limit - used) / limit * 100
    } else {
      // Counts are zero when the plan only exposes percentages.
      remainingPercent = CodingPlanJSON.number(entry[percentKey])
    }
    guard let remainingPercent else { return nil }

    let resetTime: String
    if let end = CodingPlanJSON.number(entry[endKey]), end > 0 {
      resetTime = CodingPlanJSON.iso8601(epoch: end)
    } else if let remains = CodingPlanJSON.number(entry[remainsKey]), remains > 0 {
      resetTime = ISO8601DateFormatter().string(from: now.addingTimeInterval(remains / 1000))
    } else {
      resetTime = ""
    }
    return QuotaMetric(
      name: name,
      percentage: max(0, min(100, remainingPercent)),
      resetTime: resetTime,
      used: used.map { Int($0.rounded()) },
      limit: limit.map { Int($0.rounded()) },
      remaining: limit.flatMap { total in used.map { Int(max(0, total - $0).rounded()) } }
    )
  }
}
