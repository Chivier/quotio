import Foundation
import QuotioDomain

/// Lenient JSON readers shared by the Kimi Code and MiniMax coding-plan mappers. Both
/// services return loosely typed numbers (strings, integers, or doubles) and several
/// spellings for the same field.
enum CodingPlanJSON {
  static func object(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  static func object(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func number(_ value: Any?) -> Double? {
    switch value {
    case let value as NSNumber: value.doubleValue
    case let value as String: Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default: nil
    }
  }

  static func string(_ object: [String: Any]?, keys: [String]) -> String? {
    guard let object else { return nil }
    for key in keys {
      if let value = object[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      } else if let value = object[key] as? NSNumber {
        return value.stringValue
      }
    }
    return nil
  }

  static func resetTime(in detail: [String: Any], window: [String: Any]? = nil, now: Date)
    -> String
  {
    for source in [detail, window].compactMap({ $0 }) {
      for key in ["reset_at", "resetAt", "reset_time", "resetTime", "next_reset_at"] {
        guard let value = source[key] else { continue }
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if let epoch = Double(trimmed) { return iso8601(epoch: epoch) }
          if !trimmed.isEmpty { return trimmed }
        } else if let epoch = number(value) {
          return iso8601(epoch: epoch)
        }
      }
      for key in ["reset_in", "resetIn", "reset_in_seconds", "ttl", "remaining_seconds"] {
        if let seconds = number(source[key]), seconds >= 0 {
          return ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
        }
      }
    }
    return ""
  }

  /// Accepts epoch seconds or milliseconds.
  static func iso8601(epoch: Double) -> String {
    ISO8601DateFormatter().string(from: date(epoch: epoch))
  }

  static func date(epoch: Double) -> Date {
    Date(timeIntervalSince1970: epoch > 1_000_000_000_000 ? epoch / 1000 : epoch)
  }

  static func metric(
    name: String,
    detail: [String: Any],
    window: [String: Any]? = nil,
    now: Date
  ) -> QuotaMetric? {
    let limit = number(detail["limit"] ?? detail["total"] ?? detail["quota"])
    let used = number(detail["used"] ?? detail["consumed"])
    let remaining = number(detail["remaining"] ?? detail["left"])
    let explicitRemainingPercent = number(
      detail["remaining_percent"] ?? detail["remainingPercent"])

    let remainingPercent: Double?
    if let limit, limit > 0, let used {
      remainingPercent = (limit - used) / limit * 100
    } else if let limit, limit > 0, let remaining {
      remainingPercent = remaining / limit * 100
    } else {
      remainingPercent = explicitRemainingPercent
    }
    guard let remainingPercent else { return nil }

    let derivedRemaining = remaining ?? limit.flatMap { total in used.map { max(0, total - $0) } }
    return QuotaMetric(
      name: name,
      percentage: max(0, min(100, remainingPercent)),
      resetTime: resetTime(in: detail, window: window, now: now),
      used: used.map { Int($0.rounded()) },
      limit: limit.map { Int($0.rounded()) },
      remaining: derivedRemaining.map { Int($0.rounded()) }
    )
  }
}
