import Foundation
import QuotioDomain

/// Maps a Kimi Code `/usages` response to the rolling (five-hour) window and the weekly
/// subscription usage.
enum KimiQuotaMapper {
  static let fiveHourMetric = "kimi-five-hour"
  static let weeklyMetric = "kimi-weekly"

  static func map(_ data: Data, now: Date) -> ProviderQuota? {
    guard let json = CodingPlanJSON.object(data) else { return nil }
    let root = CodingPlanJSON.object(json["data"]) ?? json
    var metrics: [QuotaMetric] = []

    if let limits = root["limits"] as? [Any] {
      // The shortest window is the rolling session limit.
      let ordered = limits.compactMap {
        item -> (duration: Double?, detail: [String: Any], window: [String: Any]?)? in
        guard let item = item as? [String: Any] else { return nil }
        let window = CodingPlanJSON.object(item["window"])
        return (durationSeconds(window), CodingPlanJSON.object(item["detail"]) ?? item, window)
      }.sorted { lhs, rhs in
        switch (lhs.duration, rhs.duration) {
        case let (left?, right?): left < right
        case (.some, nil): true
        default: false
        }
      }
      if let first = ordered.first,
        let metric = CodingPlanJSON.metric(
          name: fiveHourMetric, detail: first.detail, window: first.window, now: now)
      {
        metrics.append(metric)
      }
    }

    if let usage = CodingPlanJSON.object(root["usage"]),
      let weekly = CodingPlanJSON.metric(
        name: weeklyMetric, detail: usage, window: CodingPlanJSON.object(usage["window"]),
        now: now)
    {
      metrics.append(weekly)
    }

    guard !metrics.isEmpty else { return nil }
    let plan =
      CodingPlanJSON.string(
        root,
        keys: ["plan", "plan_name", "subscription_plan", "tier", "membership", "level", "product"]
      )
      ?? CodingPlanJSON.string(
        CodingPlanJSON.object(root["subscription"]), keys: ["name", "plan", "tier", "level"])
    let displayName =
      CodingPlanJSON.string(root, keys: ["email", "user_email"])
      ?? CodingPlanJSON.string(CodingPlanJSON.object(root["user"]), keys: ["email"])
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: displayName)
  }

  private static func durationSeconds(_ window: [String: Any]?) -> Double? {
    guard let window, let duration = CodingPlanJSON.number(window["duration"]) else { return nil }
    let unit =
      CodingPlanJSON.string(window, keys: ["timeUnit", "time_unit", "unit"])?.uppercased() ?? ""
    if unit.contains("MINUTE") { return duration * 60 }
    if unit.contains("HOUR") { return duration * 3600 }
    if unit.contains("DAY") { return duration * 86400 }
    return duration
  }
}
