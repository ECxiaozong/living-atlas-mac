import Foundation
import GRDB

public struct ResearchCandidate: Codable, Identifiable, Sendable {
  public var id: String { url.absoluteString }
  public let title: String, url: URL, snippet: String
  public var query: String? = nil
}
public struct ResearchPage: Codable, Identifiable, Sendable {
  public let id, title, text, method, captured: String
  public let url: URL
  public let query: String?
}
public struct ResearchAttempt: Codable, Identifiable, Sendable {
  public let id, kind, input, started: String
  public var status: String
}
public struct ResearchLog: Codable, Identifiable, Sendable {
  public let id: String
  public var cancelled = false
  public var attempts: [ResearchAttempt] = []
  public var candidates: [ResearchCandidate] = []
  public var pages: [ResearchPage] = []
}
public struct FrozenWebPage: Identifiable {
  public let id, title, body, version, url, captured: String
  public let saved: Bool
  public var selectedRange: NSRange?
}

public enum ExternalResearch {
  public static func address(_ value: String) throws -> URL {
    guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 8192
    else {
      throw AtlasStoreError.invalid("请输入带主机名的 http 或 https 网页地址。")
    }
    return url
  }
  private static func call(
    _ method: String, parameters: [String: Any], key: String, session: URLSession?
  ) async throws -> Data {
    guard !key.isEmpty else { throw AtlasStoreError.invalid("请先在模型设置中保存 DeepSeek 凭据。") }
    let owned = URLSession(
      configuration: .ephemeral, delegate: ProviderProfile.DirectRequest(), delegateQueue: nil)
    defer { owned.finishTasksAndInvalidate() }
    var req = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/" + method)!)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    try Task.checkCancellation()
    let (data, response) = try await (session ?? owned).data(for: req)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw ServiceError.protocolError }
    guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
    return data
  }
  public static func search(_ query: String, key: String, session: URLSession? = nil) async throws
    -> [ResearchCandidate]
  {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      query.unicodeScalars.count <= 128
    else { throw AtlasStoreError.invalid("研究查询限 1 至 128 个字符。") }
    let data = try await call(
      "search", parameters: ["query": query, "count": 5, "need_content": false], key: key,
      session: session)
    struct Results: Decodable { let results: [ResearchCandidate] }
    return try JSONDecoder().decode(Results.self, from: data).results.prefix(5).filter {
      (try? address($0.url.absoluteString)) != nil
    }.map {
      var c = $0
      c.query = query
      return c
    }
  }
  public static func fetch(_ url: URL, query: String?, key: String, session: URLSession? = nil)
    async throws -> ResearchPage
  {
    _ = try address(url.absoluteString)
    let data = try await call(
      "fetch", parameters: ["url": url.absoluteString], key: key, session: session)
    struct Fetched: Decodable { let title, content: String }
    let result = try JSONDecoder().decode(Fetched.self, from: data)
    guard !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AtlasStoreError.invalid("网页读取未返回正文。")
    }
    return ResearchPage(
      id: UUID().uuidString.lowercased(),
      title: result.title.isEmpty ? url.host ?? "网页" : result.title, text: result.content,
      method: "deepseek_fetch", captured: Date.now.ISO8601Format(), url: url, query: query)
  }
  public static func pasted(_ text: String, url: URL) throws -> ResearchPage {
    _ = try address(url.absoluteString)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AtlasStoreError.invalid("请粘贴实际取得的正文。")
    }
    return ResearchPage(
      id: UUID().uuidString.lowercased(), title: url.host ?? "网页", text: text,
      method: "manual_paste", captured: Date.now.ISO8601Format(), url: url, query: nil)
  }
}

extension AtlasStore {
  private static func research(_ db: Database, id: String) throws -> ResearchLog {
    guard
      let value = try String.fetchOne(
        db, sql: "SELECT value_json FROM workspace_settings WHERE key=?",
        arguments: ["research." + id])
    else { throw AtlasStoreError.invalid("这项研究不存在。") }
    return try JSONDecoder().decode(ResearchLog.self, from: Data(value.utf8))
  }
  private static func writeResearch(_ db: Database, _ log: ResearchLog) throws {
    let text = String(decoding: try JSONEncoder().encode(log), as: UTF8.self)
    try db.execute(
      sql:
        "INSERT INTO workspace_settings VALUES (?,?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
      arguments: ["research." + log.id, text, Date.now.ISO8601Format()])
  }
  public func createResearch() throws -> ResearchLog {
    let log = ResearchLog(id: UUID().uuidString.lowercased())
    try database.write { db in try Self.writeResearch(db, log) }
    return log
  }
  public func latestResearch() throws -> ResearchLog? {
    try database.read { db in
      guard
        let id = try String.fetchOne(
          db,
          sql:
            "SELECT substr(key,10) FROM workspace_settings WHERE key LIKE 'research.%' ORDER BY rowid DESC LIMIT 1"
        )
      else { return nil }
      return try Self.research(db, id: id)
    }
  }
  public func cancelResearch(_ id: String) throws -> ResearchLog {
    try database.write { db in
      var log = try Self.research(db, id: id)
      log.cancelled = true
      for i in log.attempts.indices where log.attempts[i].status == "进行中" {
        log.attempts[i].status = "已取消"
      }
      try Self.writeResearch(db, log)
      return log
    }
  }
  public func beginResearchAttempt(_ id: String, search: Bool, input: String) throws
    -> ResearchAttempt
  {
    try database.write { db in
      var log = try Self.research(db, id: id)
      let kind = search ? "Search" : "Fetch"
      guard !log.cancelled, log.attempts.filter({ $0.kind == kind }).count < (search ? 2 : 3) else {
        throw AtlasStoreError.invalid("本次研究已取消或已用完调用次数。")
      }
      let attempt = ResearchAttempt(
        id: UUID().uuidString.lowercased(), kind: kind, input: input,
        started: Date.now.ISO8601Format(), status: "进行中")
      log.attempts.append(attempt)
      try Self.writeResearch(db, log)
      return attempt
    }
  }
  public func finishResearchAttempt(
    _ id: String, attempt: String, candidates: [ResearchCandidate] = [], page: ResearchPage? = nil,
    error: String? = nil
  ) throws -> ResearchLog {
    try database.write { db in
      var log = try Self.research(db, id: id)
      guard !log.cancelled,
        let pos = log.attempts.firstIndex(where: { $0.id == attempt && $0.status == "进行中" })
      else { return log }
      log.attempts[pos].status = error ?? "完成"
      if error == nil {
        var seen = Set(log.candidates.map(\.id))
        log.candidates += candidates.prefix(5).filter { seen.insert($0.id).inserted }
        if let page { log.pages.append(page) }
      }
      try Self.writeResearch(db, log)
      return log
    }
  }
  public func freezeWeb(_ page: ResearchPage, quote: String, offset: Int = 0, save: Bool) throws
    -> String
  {
    guard !quote.isEmpty, offset >= 0, offset <= page.text.unicodeScalars.count,
      String(page.text.unicodeScalars.dropFirst(offset).prefix(quote.unicodeScalars.count)).utf8
        .elementsEqual(quote.utf8)
    else { throw AtlasStoreError.invalid("所选引文必须来自已读取的网页正文。") }
    return try database.write { db in
      let existing = try Row.fetchOne(
        db,
        sql:
          "SELECT document_id,id FROM document_version WHERE id=? AND source_url=? AND text_sha256=?",
        arguments: [page.id, page.url.absoluteString, atlasHash(Data(page.text.utf8))])
      let doc: String
      if let existing {
        doc = existing["document_id"]
      } else {
        doc = UUID().uuidString.lowercased()
        try db.execute(
          sql:
            "INSERT INTO document(id,kind,title,source_only,current_version_id,created_at) VALUES (?,'web_snapshot',?,1,?,?)",
          arguments: [doc, page.title, page.id, page.captured])
        let meta = try JSONSerialization.data(withJSONObject: [
          "method": page.method, "query": page.query as Any? ?? NSNull(),
        ])
        try db.execute(
          sql:
            "INSERT INTO document_version(id,document_id,ordinal,markdown_text,plain_text,text_sha256,source_metadata_json,source_url,fetched_at,extraction_status,created_at) VALUES (?,?,1,?,?,?,?,?,?,'complete',?)",
          arguments: [
            page.id, doc, page.text, page.text, atlasHash(Data(page.text.utf8)),
            String(decoding: meta, as: UTF8.self), page.url.absoluteString, page.captured,
            page.captured,
          ])
      }
      if save {
        try db.execute(
          sql: "UPDATE document SET source_only=0,revision=revision+1 WHERE id=? AND source_only=1",
          arguments: [doc])
      }
      let ref = UUID().uuidString.lowercased()
      try db.execute(
        sql:
          "INSERT INTO reference_snapshot(id,source_kind,document_version_id,quote_snapshot,created_at) VALUES (?,'document',?,?,?)",
        arguments: [ref, page.id, quote, Date.now.ISO8601Format()])
      try db.execute(
        sql:
          "INSERT INTO source_anchor(id,reference_id,segment_order,selector_type,offset_unit,start_offset,end_offset,text_sha256) VALUES (?,?,0,'text','unicode_code_points',?,?,?)",
        arguments: [
          UUID().uuidString.lowercased(), ref, offset, offset + quote.unicodeScalars.count,
          atlasHash(Data(quote.utf8)),
        ])
      return ref
    }
  }
  public func frozenWeb(document: String? = nil, reference: String? = nil) throws -> FrozenWebPage?
  {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql:
            "SELECT d.id,d.title,d.source_only,v.id AS vid,v.markdown_text,v.source_url,v.fetched_at FROM document d JOIN document_version v ON v.document_id=d.id WHERE d.kind='web_snapshot' AND ((d.id=? AND v.id=d.current_version_id) OR v.id=(SELECT document_version_id FROM reference_snapshot WHERE id=?))",
          arguments: [document, reference])
      else { return nil }
      var selection: NSRange?
      if let reference,
        let pos = try Row.fetchOne(
          db,
          sql:
            "SELECT start_offset,end_offset FROM source_anchor WHERE reference_id=? AND segment_order=0",
          arguments: [reference])
      {
        selection = try AnswerExcerpt(
          runID: reference, body: row["markdown_text"], start: pos["start_offset"],
          end: pos["end_offset"]
        ).nativeRange
      }
      return FrozenWebPage(
        id: row["id"], title: row["title"], body: row["markdown_text"], version: row["vid"],
        url: row["source_url"], captured: row["fetched_at"],
        saved: (row["source_only"] as Int) == 0, selectedRange: selection)
    }
  }
}
