import Foundation
import GRDB

/// Only provider-reported counts. A missing value remains nil, including after cancellation.
public struct RunUsage: Codable, Equatable, Sendable {
  public let input, output, cachedInput, cacheWrite: Int?
  public let cacheMiss: Int?
  public let fields: [String: Int]?
  public var status: String {
    if input != nil && output != nil { return "complete" }
    return fields?.isEmpty == false ? "partial" : "unknown"
  }
  private static func numeric(_ object: [String: Any], keys: [String]) -> [String: Int] {
    var result = [String: Int]()
    for key in keys {
      if let n = object[key] as? Int, n >= 0 { result[key] = n }
    }
    return result
  }
  init(chat: [String: Any]) {
    var reported = Self.numeric(
      chat,
      keys: [
        "prompt_tokens", "completion_tokens", "total_tokens", "prompt_cache_hit_tokens",
        "prompt_cache_miss_tokens", "cache_write_input_tokens",
      ])
    if let details = chat["prompt_tokens_details"] as? [String: Any],
      let cached = details["cached_tokens"] as? Int
    {
      reported["prompt_tokens_details.cached_tokens"] = cached
    }
    fields = reported
    cacheMiss = reported["prompt_cache_miss_tokens"]
    input = chat["prompt_tokens"] as? Int
    output = chat["completion_tokens"] as? Int
    cachedInput =
      (chat["prompt_cache_hit_tokens"] as? Int)
      ?? ((chat["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
    cacheWrite = chat["cache_write_input_tokens"] as? Int
  }
  init(cli: [String: Any]) {
    fields = Self.numeric(
      cli,
      keys: [
        "inputTokens", "outputTokens", "cachedInputTokens", "cacheWriteInputTokens",
        "reasoningOutputTokens", "totalTokens",
      ])
    cacheMiss = nil
    input = cli["inputTokens"] as? Int
    output = cli["outputTokens"] as? Int
    cachedInput = cli["cachedInputTokens"] as? Int
    cacheWrite = cli["cacheWriteInputTokens"] as? Int
  }
}

extension AtlasStore {
  public func recordUsage(_ usage: RunUsage, for run: String) throws {
    let json = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
    try database.write { db in
      try db.execute(
        sql:
          "UPDATE generation_run SET usage_json=json_patch(coalesce(usage_json,'{}'),?) WHERE id=? AND status IN ('queued','preparing','streaming')",
        arguments: [json, run])
    }
  }
  public func recordFinishReason(_ reason: String, for run: String) throws {
    try database.write { db in
      try db.execute(
        sql:
          "UPDATE generation_run SET config_json=json_set(config_json,'$.metrics.provider_finish_reason',?) WHERE id=? AND status IN ('queued','preparing','streaming')",
        arguments: [reason, run])
    }
  }
  public func usage(for run: String) throws -> RunUsage? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT usage_json FROM generation_run WHERE id=?", arguments: [run]
      )
      .map { try JSONDecoder().decode(RunUsage.self, from: Data($0.utf8)) }
    }
  }
}
