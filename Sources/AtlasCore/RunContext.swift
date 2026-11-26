import Foundation
import GRDB

public struct ContextSettings: Codable, Equatable {
  public enum Scope: String, Codable { case branch, direct, selection }
  public var scope: Scope
  public var inputBudget: Int
  public init(includePath: Bool = true, inputBudget: Int = 16000) {
    scope = includePath ? .branch : .selection
    self.inputBudget = inputBudget
  }
  private enum CodingKeys: String, CodingKey { case scope, inputBudget }
  private enum LegacyKeys: String, CodingKey { case includePath }
  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    inputBudget = try fields.decode(Int.self, forKey: .inputBudget)
    if let value = try fields.decodeIfPresent(Scope.self, forKey: .scope) { scope = value }
    else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      scope = try legacy.decode(Bool.self, forKey: .includePath) ? .branch : .selection
    }
  }
}

private struct ContextSource {
  let object, version, kind, selection, text: String
  let anchor: String?
  let state: String
  let message: ProviderMaterial
  let full: Bool
  var locator: String? = nil
  var pageIndex: Int? = nil
  var sourceHash: String? = nil

  var dependencies: [[String: String]] = []

  func wireMaterial() -> ProviderMaterial {
    let identity = [kind, version, locator].compactMap { $0 }.joined(separator: " · ")
    let payload = "〔" + identity + "〕\n" + text
    switch message {
    case .quotation: return .quotation(payload)
    case .previousQuestion: return .previousQuestion(payload)
    case .history: return .history(payload)
    }
  }
  func manifest(index: Int, workspace: String) -> [String: Any] {
    [
      "material_id": String(format: "M%03d", index + 1),
      "source": [
        "kind": kind, "workspace_id": workspace, "object_id": object, "version_id": version,
      ],
      "anchor_id": anchor as Any? ?? NSNull(), "source_state_at_capture": state,
      "selection_kind": selection, "read_level": full ? "full" : "excerpt",
      "provided": ["format": "text", "text": text, "sha256": atlasHash(Data(text.utf8))],
      "dependency_refs": dependencies, "utf8_bytes": text.utf8.count,
      "source_text_sha256": sourceHash ?? atlasHash(Data(text.utf8)),
      "physical_page_index": pageIndex as Any? ?? NSNull(),
    ]
  }
}

extension AtlasStore {
  static func tokenEstimate(_ bytes: Data) -> Int {
    let scalars = String(decoding: bytes, as: UTF8.self).unicodeScalars
    let ascii = scalars.reduce(0) { $0 + ($1.isASCII ? 1 : 0) }
    return scalars.count - ascii + (ascii + 3) / 4
  }

  /// Select intact neighboring sentences when a long answer exceeds the bounded window.
  private static func readingPassage(_ window: String, quote: String, start: Int) -> String {
    let scalars = window.unicodeScalars
    guard let lower = scalars.index(scalars.startIndex, offsetBy: start, limitedBy: scalars.endIndex),
      let upper = scalars.index(lower, offsetBy: quote.unicodeScalars.count, limitedBy: scalars.endIndex)
    else { return window }
    let before = scalars[..<lower], after = scalars[upper...]
    guard before.count == 768 || after.count == 768 else { return window }
    let separators = CharacterSet(charactersIn: "。！？!?\n")
    // The punctuation immediately adjacent to the selection can end the previous
    // sentence or the selected one. Keep a complete neighbor on each side.
    let ignorable = separators.union(.whitespaces)
    let previousContent = before.lastIndex { !ignorable.contains($0) }
    let left = previousContent.flatMap { before[..<$0].lastIndex(where: separators.contains) }
      .map { scalars.index(after: $0) } ?? scalars.startIndex
    let nextContent = after.firstIndex { !ignorable.contains($0) }
    let right = nextContent.flatMap { after[$0...].firstIndex(where: separators.contains) }
      .map { scalars.index(after: $0) } ?? scalars.endIndex
    return String(scalars[left..<right]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Deterministic extracts keep attribution and uncertainty in the source words.
  /// Only already-authorized members of this turn are eligible for local reuse.
  private static func historyExtract(_ db: Database, turn: [ContextSource], policy: Int) throws -> ContextSource? {
    guard let first = turn.first else { return nil }
    let deps = turn.map { ["object_id": $0.object, "version_id": $0.version, "kind": $0.kind,
      "text_sha256": atlasHash(Data($0.text.utf8))] }
    let keyData = try JSONSerialization.data(withJSONObject: deps, options: [.sortedKeys])
    let key = "view.context.extract.v1." + String(policy) + "." + atlasHash(keyData)
    let text: String
    if let cached = try String.fetchOne(db, sql: "SELECT json_extract(value_json,'$') FROM workspace_settings WHERE key=?", arguments: [key]) {
      text = cached
    } else {
      text = turn.map { source in
        let role: String
        switch source.message {
        case .previousQuestion: role = "当时的问题"
        case .history: role = "当时的回答"
        case .quotation: role = "当时的引文"
        }
        let cut = source.text.prefix(110)
        return role + "：" + cut + (cut.endIndex == source.text.endIndex ? "" : "…")
      }.joined(separator: "\n")
      try db.execute(sql: "INSERT OR IGNORE INTO workspace_settings VALUES (?,json_quote(?),1,?)",
        arguments: [key, text, Date.now.ISO8601Format()])
    }
    return ContextSource(object: first.object, version: first.version, kind: first.kind,
      selection: "summary", text: text, anchor: nil, state: first.state, message: .quotation(text),
      full: false, locator: "较早讨论的逐字摘录", dependencies: deps)
  }

  public func contextSettings() throws -> ContextSettings {
    try readViewState(ContextSettings.self, key: "context") ?? ContextSettings()
  }
  public func setContextSettings(_ settings: ContextSettings) throws {
    guard (1...16000).contains(settings.inputBudget) else {
      throw AtlasStoreError.invalid("普通问答输入预算为 1 至 16000。")
    }
    let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    try database.write { db in
      let prior = try String.fetchOne(db, sql: "SELECT value_json FROM workspace_settings WHERE key='view.context'")
      let existing = try prior.map { try JSONDecoder().decode(ContextSettings.self, from: Data($0.utf8)) } ?? ContextSettings()
      guard existing != settings else { return }
      try db.execute(
        sql:
          "INSERT INTO workspace_settings VALUES ('view.context',?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
        arguments: [text, Date.now.ISO8601Format()])
      try db.execute(
        sql: "UPDATE workspace SET policy_revision=policy_revision+1 WHERE singleton=1")
    }
  }
  public func materialManifest(_ run: String) throws -> String? {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT material_manifest_json FROM generation_run WHERE id=?", arguments: [run])
    }
  }

  /// Freeze both the evidence and the exact credential-free request before clearing the composer.
  static func freezeRequest(_ db: Database, run: String, profile: ProviderProfile) throws {
    guard
      let record = try Row.fetchOne(
        db,
        sql: """
          SELECT r.turn_id,r.request_id,r.policy_revision_at_start,q.body_markdown AS question,w.id AS workspace
          FROM generation_run r JOIN inquiry_turn t ON t.id=r.turn_id JOIN content_version q ON q.id=t.question_version_id
          JOIN workspace w ON w.singleton=1 WHERE r.id=?
          """, arguments: [run])
    else { throw AtlasStoreError.invalid("生成记录不存在。") }
    let settings: ContextSettings
    if let raw = try String.fetchOne(
      db, sql: "SELECT value_json FROM workspace_settings WHERE key='view.context'")
    {
      settings = try JSONDecoder().decode(ContextSettings.self, from: Data(raw.utf8))
    } else {
      settings = ContextSettings()
    }
    var rounds: [[ContextSource]] = []
    var seen = Set<String>()
    var visited = Set<String>()
    var turn: String? = record["turn_id"]
    var direct = true
    while let current = turn, visited.insert(current).inserted {
      var parent: String?
      var group = [ContextSource]()
      let rows = try Row.fetchAll(
        db,
        sql: """
          WITH direct_ref AS (
            SELECT reference_id,role,ordinal FROM inquiry_reference WHERE turn_id=?
          ), relation_sources AS (
            SELECT v.* FROM direct_ref i JOIN reference_snapshot s ON s.id=i.reference_id
            JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0
            JOIN relation_version v ON v.id=s.relation_version_id
            WHERE json_extract(a.geometry_json,'$.origin')='canvas_relation'
          ), inputs AS (
            SELECT *,0 AS endpoint FROM direct_ref
            UNION ALL SELECT from_reference_id,'explicit_reference',0,1 FROM relation_sources
            UNION ALL SELECT to_reference_id,'explicit_reference',1,1 FROM relation_sources
          )
          SELECT s.*,i.role,(i.endpoint=1 AND c.body_markdown=s.quote_snapshot) AS whole_endpoint,
          a.id AS anchor_id,a.selector_type,a.page_index,a.start_offset,
          CASE WHEN i.endpoint=1 AND json_extract(a.geometry_json,'$.origin')='relation_document'
            THEN json_extract(a.geometry_json,'$.title') END AS document_title,d.ordinal AS document_ordinal,
          g.id AS parent_run,g.turn_id AS parent_turn,
          pq.id AS question_version,pq.node_id AS question_object,pq.body_markdown AS parent_question, doc.title AS file_title, c.body_sha256 AS content_hash,
          length(c.body_markdown) AS answer_length,
          CASE WHEN a.selector_type='text' AND g.id IS NOT NULL THEN
            substr(c.body_markdown,max(1,a.start_offset+1-768),min(768,a.start_offset)+a.end_offset-a.start_offset+768)
          END AS surrounding_answer,
          coalesce(c.node_id,d.document_id,m.message_id,rv.relation_id,av.annotation_id) AS object,
          coalesce(s.content_version_id,s.document_version_id,s.message_version_id,s.relation_version_id,s.annotation_version_id) AS version
          FROM inputs i JOIN reference_snapshot s ON s.id=i.reference_id
          LEFT JOIN source_anchor a ON a.reference_id=s.id AND a.segment_order=0
          LEFT JOIN generation_run g ON i.endpoint=0 AND i.role='actual_trigger' AND g.id=json_extract(a.geometry_json,'$.parentRunID')
          LEFT JOIN inquiry_turn pt ON pt.id=g.turn_id LEFT JOIN content_version pq ON pq.id=pt.question_version_id
          LEFT JOIN content_version c ON c.id=s.content_version_id LEFT JOIN document_version d ON d.id=s.document_version_id
          LEFT JOIN document doc ON doc.id=d.document_id
          LEFT JOIN import_message_version m ON m.id=s.message_version_id LEFT JOIN relation_version rv ON rv.id=s.relation_version_id
          LEFT JOIN annotation_version av ON av.id=s.annotation_version_id WHERE (? OR g.id IS NULL OR a.selector_type<>'whole')
          ORDER BY i.role='actual_trigger' DESC,i.endpoint,i.ordinal
          """, arguments: [current, settings.scope != .selection])
      for r in rows {
        let id: String = r["id"]
        let isParent = (r["parent_run"] as String?) != nil
        if isParent { parent = r["parent_turn"] }
        guard seen.insert(id).inserted else { continue }
        let text: String
        if let q: String = r["quote_snapshot"], !q.isEmpty {
          text = q
        } else if let title: String = r["document_title"], let ordinal: Int = r["document_ordinal"] {
          text = "文档题名《" + title + "》 · 版本 " + String(ordinal) + "（仅引用题名与版本，未附正文）"
        } else if let p: Int = r["page_index"] {
          text = "引用第 \(p+1) 页，仅有页码，未读取图像或正文。"
        } else {
          throw AtlasStoreError.invalid("指定的来源暂无法读取，问题已保留。")
        }
        // A whole implicit ancestor is outside selection-only scope. Explicit excerpt triggers stay.
        if settings.scope == .selection, isParent, (r["selector_type"] as String?) == "whole" { continue }
        if settings.scope != .selection, isParent, let prior: String = r["parent_question"] {
          group.append(ContextSource(
            object: r["question_object"], version: r["question_version"], kind: "content",
            selection: "history", text: prior, anchor: nil, state: "available",
            message: .previousQuestion(prior), full: true))
          if let neighborhood: String = r["surrounding_answer"] {
            let passage = Self.readingPassage(neighborhood, quote: text, start: min(768, r["start_offset"] as Int))
            group.append(ContextSource(
              object: r["object"], version: r["version"], kind: r["source_kind"],
              selection: "history", text: passage, anchor: nil, state: r["source_state_at_capture"],
              message: .history(passage), full: passage.unicodeScalars.count == r["answer_length"] as Int?, sourceHash: r["content_hash"]))
          }
        }
        group.append(
          ContextSource(
            object: r["object"], version: r["version"], kind: r["source_kind"],
            selection: direct
              ? ((r["role"] as String) == "actual_trigger" ? "origin" : "explicit") : "history",
            text: text, anchor: r["anchor_id"], state: r["source_state_at_capture"],
            message: isParent && (settings.scope == .selection || r["selector_type"] as String? == "whole")
              ? .history(text) : .quotation(text),
            full: ((r["selector_type"] as String?) == "whole" && r["document_title"] as String? == nil) || (r["whole_endpoint"] as Bool?) == true,
            locator: (r["file_title"] as String?).map { title in
              title + " · 版本 " + String(r["document_ordinal"] as Int) +
                ((r["page_index"] as Int?).map { " · 物理第 " + String($0 + 1) + " 页" } ?? "")
            }, pageIndex: r["page_index"], sourceHash: r["content_hash"]))
      }
      rounds.append(group)
      turn = settings.scope == .branch ? parent : nil
      direct = false
    }
    let question: String = record["question"]
    let workspace: String = record["workspace"]
    // Build from immutable source versions. Admit complete turns nearest-first, then serialize chronologically.
    var materials = rounds.first ?? []
    let task: AnswerTask
    if materials.isEmpty { task = .general }
    else if settings.scope == .selection { task = .selection }
    else if materials.contains(where: { if case .previousQuestion = $0.message { return true }; return false }) { task = .followup }
    else { task = .source }
    func prepare(_ sources: [ContextSource]) throws -> PreparedProviderRequest {
      try profile.prepare(question: question, materials: sources.map { settings.scope == .selection ? $0.message : $0.wireMaterial() }, task: task)
    }
    var prepared = try prepare(materials)
    guard prepared.body.count <= settings.inputBudget else {
      throw AtlasStoreError.invalid("问题、明确引用和直接来源合计超过输入字节预算。草稿已保留，可缩短选段或调整预算。")
    }
    var omitted: [[String: Any]] = []
    for older in rounds.dropFirst() {
      let expanded = older + materials
      let candidate = try prepare(expanded)
      if candidate.body.count <= settings.inputBudget {
        materials = expanded
        prepared = candidate
        continue
      }
      if let extract = try historyExtract(db, turn: older, policy: record["policy_revision_at_start"]) {
        let compact = try prepare([extract] + materials)
        if compact.body.count <= settings.inputBudget {
          materials.insert(extract, at: 0)
          prepared = compact
          continue
        }
      }
      omitted += older.map { ["source": ["kind": $0.kind, "workspace_id": workspace,
        "object_id": $0.object, "version_id": $0.version], "reason": "budget"] }
    }
    let identity =
      profile.endpoint.absoluteString + "|" + (profile.subscriptionAccount ?? "") + "|"
      + profile.model
    let profileKey = "profile.identity." + atlasHash(Data(identity.utf8))
    let profileID: String
    if let existing = try String.fetchOne(
      db, sql: "SELECT json_extract(value_json,'$') FROM workspace_settings WHERE key=?",
      arguments: [profileKey])
    {
      profileID = existing
    } else {
      profileID = UUID().uuidString.lowercased()
      try db.execute(
        sql: "INSERT INTO workspace_settings VALUES (?,json_quote(?),1,?)",
        arguments: [profileKey, profileID, Date.now.ISO8601Format()])
    }
    let manifest: [String: Any] = [
      "schema_version": "context-manifest/2", "manifest_id": UUID().uuidString.lowercased(),
      "run_id": run,
      "request_attempt_id": record["request_id"] as String, "workspace_id": workspace,
      "created_at": Date.now.ISO8601Format(),
      "provider_profile_id": profileID, "model_id": profile.model,
      "scope_snapshot": [
        "scope_id": UUID().uuidString.lowercased(),
        "policy_revision": record["policy_revision_at_start"] as Int,
        "mode": settings.scope.rawValue, "allowed_workspace_ids": [workspace],
        "selected_object_ids": Array(Set(materials.map(\.object))).sorted(),
        "allow_cross_branch": false,
      ] as [String: Any],
      "prompt": [
        "template_id": task.rawValue, "version": "3", "system_text_sha256": prepared.systemPromptHash,
      ],
      "budget": [
        "input_limit_bytes": settings.inputBudget, "request_bytes": prepared.body.count,
        "planning_window_tokens": 24000, "safety_margin_tokens": 2400, "provider_context_window_tokens": NSNull(),
        "reserved_output_tokens": 4000, "estimated_input_tokens": Self.tokenEstimate(prepared.body),
        "estimate_method": "non-ASCII scalars + ASCII bytes / 4, rounded up; heuristic",
      ] as [String: Any],
      "materials": materials.enumerated().map {
        $0.element.manifest(index: $0.offset, workspace: workspace)
      },
      "omitted_materials": omitted, "request_payload_sha256": prepared.payloadHash,
    ]
    let json = String(
      decoding: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
      as: UTF8.self)
    let cli = try profile.isCodexCLI ? CodexCLI.envelope(prepared.body) : nil
    let config = String(
      decoding: try JSONSerialization.data(withJSONObject: [
        "request_body": prepared.body.base64EncodedString(),
        "capabilities": profile.capabilities,
        "adapter": profile.isCodexCLI ? "codex-app-server" : "http",
        "cli_input": cli.map { ["baseInstructions": $0.instructions, "turn_input_text": $0.text,
          "turn_input_sha256": atlasHash(Data($0.text.utf8))] } as Any? ?? NSNull(),
        "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)),
        "output_limit_sent": prepared.sentOutputTokens as Any? ?? NSNull(),
        "estimate": "credential-free request UTF-8 bytes",
      ]), as: UTF8.self)
    try db.execute(
      sql: "UPDATE generation_run SET material_manifest_json=?,config_json=? WHERE id=?",
      arguments: [json, config, run])
  }
  public func frozenCLIInput(for run: String) throws -> CodexCLI.Input? {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: """
        SELECT json_extract(config_json,'$.cli_input.baseInstructions') AS policy,
          json_extract(config_json,'$.cli_input.turn_input_text') AS text,
          json_extract(config_json,'$.cli_input.turn_input_sha256') AS checksum,
          json_extract(material_manifest_json,'$.prompt.system_text_sha256') AS policy_hash
        FROM generation_run WHERE id=?
        """, arguments: [run]), let text: String = row["text"] else { return nil }
      guard let policy: String = row["policy"],
        atlasHash(Data(text.utf8)) == row["checksum"] as String?,
        atlasHash(Data(policy.utf8)) == row["policy_hash"] as String?
      else { throw AtlasStoreError.invalid("冻结的 CLI 输入未通过校验。") }
      return CodexCLI.Input(instructions: policy, text: text)
    }
  }

  public func frozenProfile(for run: String) throws -> ProviderProfile {
    try database.read { db in
      guard
        let json = try String.fetchOne(
          db, sql: "SELECT json_extract(config_json,'$.profile') FROM generation_run WHERE id=?",
          arguments: [run])
      else { throw AtlasStoreError.invalid("无法读取生成时的模型配置。") }
      return try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
    }
  }
  public func frozenBody(for run: String) throws -> Data {
    try database.read { db in
      guard
        let r = try Row.fetchOne(
          db,
          sql:
            "SELECT json_extract(config_json,'$.request_body') AS body,json_extract(material_manifest_json,'$.request_payload_sha256') AS digest FROM generation_run WHERE id=?",
          arguments: [run]),
        let b: String = r["body"], let data = Data(base64Encoded: b),
        atlasHash(data) == (r["digest"] as String?)
      else { throw AtlasStoreError.invalid("冻结请求未通过校验。") }
      return data
    }
  }
}
