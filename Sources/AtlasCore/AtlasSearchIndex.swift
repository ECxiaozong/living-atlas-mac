import Foundation
import GRDB
import NaturalLanguage

enum AtlasSearchText {
  static func fold(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping.lowercased()
  }
  static let identifier = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z_0-9]*")
  static let wordBoundary = try! NSRegularExpression(
    pattern: "(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|_+")
  static func tokens(_ source: String) -> [String] {
    let original = source.precomposedStringWithCompatibilityMapping
    let text = fold(original)
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var terms: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
      terms.append(String(text[r]))
      return true
    }
    var last: Unicode.Scalar?
    for c in text.unicodeScalars {
      let n = c.value
      if (0x3400...0x4dbf).contains(n) || (0x4e00...0x9fff).contains(n)
        || (0x20000...0x323af).contains(n)
      {
        if let last { terms.append(String(last) + String(c)) }
        last = c
      } else {
        last = nil
      }
    }
    let ns = original as NSString
    for m in identifier.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
      let name = ns.substring(with: m.range)
      terms.append(name.lowercased())
      let split = wordBoundary.stringByReplacingMatches(
        in: name, range: NSRange(location: 0, length: (name as NSString).length), withTemplate: " ")
      terms += split.lowercased().split(separator: " ").map(String.init)
    }
    return terms.filter { !$0.isEmpty && $0.utf8.count < 256 }
  }

  /// Whole words carry more information than overlapping Han bigrams in a remembered sentence.
  /// Keep exact substring matching first and the ordinary token search as a fallback.
  static func sentenceTerms(_ query: String, literal: [String]) -> [String]? {
    guard query.count >= 8, let language = NLLanguageRecognizer.dominantLanguage(for: query),
      language == .simplifiedChinese || language == .traditionalChinese else { return nil }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = query
    var words = [String]()
    tokenizer.enumerateTokens(in: query.startIndex..<query.endIndex) { range, _ in
      let word = fold(String(query[range]))
      if word.count > 1 && !words.contains(word) { words.append(word) }
      return words.count < 12
    }
    guard words.count >= 3 else { return nil }
    var neighbours = [String]()
    if let embedding = NLEmbedding.wordEmbedding(for: language) {
      for word in words {
        for (term, distance) in embedding.neighbors(for: word, maximumCount: 4)
          where distance < 0.95 && term.count > 1 && !neighbours.contains(term) {
          neighbours.append(term)
        }
      }
    }
    // Naming an edge in ordinary Chinese can match its indexed kind even if its explanation
    // describes only the two subjects. All content kinds still compete on their own words.
    if ["关系线", "连线", "连接线", "条线"].contains(where: query.contains) { words.append("连线") }
    // Repeated FTS clauses weight whole user terms above fragments and vector neighbours.
    return words + words + words + Array(literal.filter { $0.count > 1 }.prefix(48)) + neighbours
  }

  /// Some Chinese descriptions refer to a concept without sharing its indexed vocabulary.
  /// Require both cues for ambiguous words such as “转” or “串”.
  static func conceptGroups(_ query: String) -> [[String]] {
    func mentions(_ options: [String]) -> Bool { options.contains(where: query.contains) }
    var groups: [[String]] = []
    let screen = mentions(["屏幕", "桌面", "画面", "手机", "显示器", "平板"])
    if screen, mentions(["横屏", "竖屏", "横过来", "竖过来", "横竖切换"])
      || query.range(of: #"(?:转|换)(?:了?一个|了?个|了|一下)?方向"#, options: .regularExpression) != nil {
      groups.append(["旋转", "横屏", "竖屏"])
    }
    let account = mentions(["账号", "帐号", "账户", "帐户"])
    if account { groups.append(["账户", "账号", "帐号", "帐户"]) }
    if mentions(["搜索历史", "查询历史", "检索历史", "搜索记录", "查询记录", "检索记录"]) {
      groups.append(["记录", "历史", "查询"])
    }
    let multipleOwners = mentions(["两个人", "不同人", "别人", "他人", "不同用户", "多个用户"])
    if account || multipleOwners,
      mentions(["串号", "串用", "混", "共用", "共享", "隔离", "同一个", "同一份"])
        || (mentions(["一起", "一块"]) && query.range(of: #"串(?:了|号|用|掉|到|[?？。，！!]|$)"#,
          options: .regularExpression) != nil) {
      var boundaries = ["用户", "隔离", "共用", "范围"]
      if !account { boundaries.append("账户") }
      groups.append(boundaries)
    }
    if let first = query.range(of: "先"), query[first.upperBound...].contains("才"),
      mentions(["理由", "原因", "依赖", "条件", "前提"]) {
      groups.append(["依赖", "前提", "先决条件"])
    }
    return groups
  }

  static func chunks(_ text: String) -> [(Int, Int, String)] {
    var out: [(Int, Int, String)] = []
    var start = text.startIndex
    var offset = 0
    while start < text.endIndex {
      let maxEnd = text.index(start, offsetBy: 1200, limitedBy: text.endIndex) ?? text.endIndex
      var end = maxEnd
      if maxEnd != text.endIndex {
        let ideal = text.index(start, offsetBy: 800)
        if let split = text[ideal..<maxEnd].firstIndex(of: "\n") { end = text.index(after: split) }
      }
      let chunk = String(text[start..<end])
      if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out.append((offset, offset + chunk.unicodeScalars.count, chunk))
      }
      if end == text.endIndex { break }
      let next = text.index(end, offsetBy: -120, limitedBy: start) ?? end
      offset += text[start..<next].unicodeScalars.count
      start = next
    }
    return out
  }
}

/// This disposable database contains searchable copies. Every search supplies a fresh allow-list from the open Atlas.
public final class AtlasSearchIndex: Sendable {
  public let store: AtlasStore
  private let index: DatabaseQueue

  public init(store: AtlasStore, cacheDirectory: URL? = nil) throws {
    self.store = store
    let cache =
      try cacheDirectory
      ?? Self.cacheDirectory(for: store.directory, workspaceID: store.workspaceID)
    try FileManager.default.createDirectory(
      at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = cache.appendingPathComponent("index.sqlite")
    func openCache() throws -> DatabaseQueue {
      let reader = try DatabaseQueue(path: file.path)
      try reader.write { db in
        if try Int.fetchOne(db, sql: "PRAGMA user_version") != 3
          || (try Int.fetchOne(
            db,
            sql:
              "SELECT count(*) FROM sqlite_master WHERE name IN ('search_fts','search_source','search_chunk','search_han')"
          )) != 4
        {
          try Self.reset(db)
        }
      }
      return reader
    }
    do { index = try openCache() } catch let failure as DatabaseError
      where failure.resultCode == .SQLITE_NOTADB || failure.resultCode == .SQLITE_CORRUPT
    {
      // Only the disposable sidecar lives here. Never apply this recovery to workspace.sqlite.
      for suffix in ["-shm", "-wal", "-journal", ""] {
        let path = URL(fileURLWithPath: file.path + suffix)
        if FileManager.default.fileExists(atPath: path.path) {
          try FileManager.default.removeItem(at: path)
        }
      }
      index = try openCache()
    }
  }

  public static func cacheDirectory(for directory: URL, workspaceID: String) throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    )
    .appendingPathComponent(
      "local.livingatlas.mac/Search/"
        + atlasHash(Data((workspaceID + directory.standardizedFileURL.path).utf8)))
  }

  /// Called after the workspace and its search sessions have closed.
  public static func removeCache(for directory: URL, workspaceID: String) throws {
    let url = try cacheDirectory(for: directory, workspaceID: workspaceID)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private static func reset(_ db: Database) throws {
    try db.execute(
      sql: """
        DROP TABLE IF EXISTS search_han; DROP TABLE IF EXISTS search_fts; DROP TABLE IF EXISTS search_chunk; DROP TABLE IF EXISTS search_source;
        CREATE TABLE search_source(key TEXT PRIMARY KEY,object_id TEXT NOT NULL,fingerprint TEXT NOT NULL);
        CREATE TABLE search_chunk(id INTEGER PRIMARY KEY,source_reference_id TEXT NOT NULL REFERENCES search_source(key) ON DELETE CASCADE,
          locator TEXT NOT NULL,start INTEGER NOT NULL,end INTEGER NOT NULL,text TEXT NOT NULL,
          normalized_search_text TEXT NOT NULL,title_tokens TEXT NOT NULL,source_sha256 TEXT NOT NULL,
          folded TEXT NOT NULL,folded_title TEXT NOT NULL, han_tokens TEXT NOT NULL, embedding BLOB);
        CREATE INDEX search_chunk_source ON search_chunk(source_reference_id);
        CREATE VIRTUAL TABLE search_fts USING fts5(title_tokens,normalized_search_text,content='search_chunk',content_rowid='id',tokenize='unicode61');
        CREATE VIRTUAL TABLE search_han USING fts5(han_tokens,content='search_chunk',content_rowid='id');
        CREATE TRIGGER search_chunk_ai AFTER INSERT ON search_chunk BEGIN
          INSERT INTO search_han(rowid,han_tokens) VALUES(new.id,new.han_tokens);
          INSERT INTO search_fts(rowid,title_tokens,normalized_search_text) VALUES(new.id,new.title_tokens,new.normalized_search_text); END;
        CREATE TRIGGER search_chunk_ad AFTER DELETE ON search_chunk BEGIN
          INSERT INTO search_han(search_han,rowid,han_tokens) VALUES('delete',old.id,old.han_tokens);
          INSERT INTO search_fts(search_fts,rowid,title_tokens,normalized_search_text) VALUES('delete',old.id,old.title_tokens,old.normalized_search_text); END;
        PRAGMA user_version=3;
        """)
  }

  // Search aliases describe the saved relation type. They do not create edges or infer direction.
  private static func relationTerms(_ relation: MapRelation) -> String {
    switch relation {
    case .compares: "无向 比较 对照 对比 区别 差异 异同 并列"
    case .depends_on: "有向 依赖 前提 必要条件 先决条件"
    case .supports: "有向 支持 论据 佐证"
    case .critiques: "有向 质疑 批判 反驳 反例"
    case .analogous_to: "无向 类比 相似 对应"
    case .reinterprets: "有向 重释 重新解释"
    case .related_to: "无向 弱关联 可能相关"
    }
  }

  /// Replace all derived rows atomically and index the currently visible sources at this Atlas's final path.
  @discardableResult public func rebuild() throws -> Int {
    try store.database.read { source in
      let entities = try store.searchEntities(source, scope: .init())
      return try index.write { db in
        try Self.reset(db)
        try synchronize(entities, from: source, into: db)
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM search_chunk") ?? 0
      }
    }
  }

  private func synchronize(_ entities: [SearchEntity], from source: Database, into db: Database)
    throws
  {
    try db.execute(
      sql:
        "CREATE TEMP TABLE IF NOT EXISTS search_allowed(key TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM search_allowed"
    )
    if let exclusions = try String.fetchOne(
      source, sql: "SELECT value_json FROM workspace_settings WHERE key='search.excluded'"),
      exclusions != "[]"
    {
      try db.execute(
        sql:
          "DELETE FROM search_chunk WHERE source_reference_id IN (SELECT key FROM search_source WHERE object_id IN (SELECT value FROM json_each(?)))",
        arguments: [exclusions])
      try db.execute(
        sql: "DELETE FROM search_source WHERE object_id IN (SELECT value FROM json_each(?))",
        arguments: [exclusions])
    }
    // Keep the permission set local to this query, including when the caller narrows its scope.
    for start in stride(from: 0, to: entities.count, by: 1024) {
      try Task.checkCancellation()
      let keys = entities[start..<min(start + 1024, entities.count)].map(\.key)
      let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
      try db.execute(sql: "INSERT INTO search_allowed SELECT value FROM json_each(?)", arguments: [json])
    }
    let saved = try Row.fetchAll(
      db, sql: "SELECT s.key,s.fingerprint FROM search_source s JOIN search_allowed USING(key)")
    let fingerprints = Dictionary(
      uniqueKeysWithValues: saved.map { (($0["key"] as String), ($0["fingerprint"] as String)) }
    )
    for e in entities {
      // Existing relation rows gain discoverable source-type terms on their next scoped query.
      let fingerprint = e.kind == .relation ? "relation-2:" + e.fingerprint : e.fingerprint
      if fingerprints[e.key] == fingerprint { continue }
      try Task.checkCancellation()
      let parts = try store.searchParts(source, e)
      try db.execute(
        sql: "DELETE FROM search_chunk WHERE source_reference_id=?; ", arguments: [e.key])
      try db.execute(
        sql: "INSERT OR REPLACE INTO search_source VALUES (?,?,?)",
        arguments: [e.key, e.object, fingerprint])
      let relation =
        e.kind == .relation ? MapRelation(rawValue: e.detail).map { "知识关系 关系线 连线 连接线 " + Self.relationTerms($0) } : nil
      let titleTokens = AtlasSearchText.tokens(e.title + " " + (relation ?? e.detail)).joined(
        separator: " ")
      for (locator, raw) in parts {
        let digest = atlasHash(Data(raw.utf8))
        for (start, end, text) in AtlasSearchText.chunks(raw) {
          try db.execute(
            sql:
              "INSERT INTO search_chunk(source_reference_id,locator,start,end,text,normalized_search_text,title_tokens,source_sha256,folded,folded_title,han_tokens) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            arguments: [
              e.key, locator, start, end, text,
              AtlasSearchText.tokens(text).joined(separator: " "), titleTokens, digest,
              AtlasSearchText.fold(text), AtlasSearchText.fold(e.title),
              ChinesePassageSearch.han(e.title + text).joined(separator: " "),
            ])
        }
      }
    }
  }

  /// Match every eligible displayed version, independently of the ranked search result limit.
  func organizationTextMatches(terms: Set<String>, versions: Set<String>) throws -> OrganizationTextMatches {
    var scope = AtlasSearchScope()
    scope.includeHistory = true
    scope.kinds = [.content, .pdf, .markdown, .web]
    return try store.database.read { source in
      let entities = try store.searchEntities(source, scope: scope).filter { versions.contains($0.version) }
      let byKey = Dictionary(uniqueKeysWithValues: entities.map { ($0.key, $0.version) })
      return try index.write { db in
        try synchronize(entities, from: source, into: db)
        let chunks = " FROM search_chunk c JOIN search_allowed a ON a.key=c.source_reference_id"
        func matchedVersions(_ suffix: String, _ arguments: StatementArguments = []) throws -> Set<String> {
          let keys = try String.fetchAll(db, sql: "SELECT DISTINCT a.key" + chunks + suffix, arguments: arguments)
          return Set(keys.compactMap { byKey[$0] })
        }
        var matches: [String: Set<String>] = [:]
        for term in terms {
          try Task.checkCancellation()
          matches[term] = try matchedVersions(" WHERE instr(c.folded,?)>0", [AtlasSearchText.fold(term)])
        }
        return OrganizationTextMatches(readable: try matchedVersions(""), matches: matches)
      }
    }
  }

  public func matches(_ query: String, scope: AtlasSearchScope = .init(), limit: Int = 40) throws
    -> [AtlasSearchHit]
  {
    try matches(queries: [query], scope: scope, limit: limit)
  }

  public func matches(queries: [String], scope: AtlasSearchScope, limit: Int = 40) throws
    -> [AtlasSearchHit]
  {
    let queries = Array(queries.prefix(16)).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !queries.isEmpty, limit > 0 else { return [] }
    let first = queries[0]
    let phrase = AtlasSearchText.fold(first)
    let sentenceQuery = queries.count == 1 && ChinesePassageSearch.han(String(first.prefix(160))).count >= 6
    let groups = queries.count == 1 ? AtlasSearchText.conceptGroups(String(first.prefix(1024))) : []
    let concepts = groups.flatMap { $0 }
    let terms = Array(Set(queries.flatMap { AtlasSearchText.tokens(String($0.prefix(1024))) }))
      .sorted()
    return try store.database.read { source in
      let entities = try store.searchEntities(source, scope: scope)
      let byKey = Dictionary(uniqueKeysWithValues: entities.map { ($0.key, $0) })
      return try index.write { db in
        try synchronize(entities, from: source, into: db)
        let table = "search_chunk c JOIN search_allowed a ON a.key=c.source_reference_id"
        var results: [AtlasSearchHit] = []
        var seen = Set<String>()
        var selectedChunks = [Int64]()
        let resultLimit = min(40, limit)
        let target = sentenceQuery ? 40 : resultLimit
        // A single book can occupy hundreds of high-ranked rows. Rank lightweight chunk IDs
        // and fetch the actual text only after selecting a distinct permitted source.
        let detail = try db.cachedStatement(sql: "SELECT * FROM search_chunk WHERE id=?")
        func appendMatches(_ sql: String, arguments: StatementArguments, related: [String] = [], semantic: Bool = false) throws {
          let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
          while results.count < target, let candidate = try rows.next() {
            guard let e = byKey[candidate["source_reference_id"]],
              seen.insert(
                e.kind.rawValue + "|" + e.object + (scope.includeHistory ? "|" + e.version : "")
              ).inserted
            else { continue }
            let chunkID: Int64 = candidate["id"]
            guard let r = try Row.fetchOne(detail, arguments: [chunkID]) else {
              throw AtlasStoreError.invalid("检索片段不存在")
            }
            selectedChunks.append(chunkID)
            let raw: String = r["text"]
            let title =
              e.title.isEmpty
              ? (e.kind == .relation ? MapRelation(rawValue: e.detail)?.label : nil)
                ?? String((raw.split(separator: "\n").first ?? raw[...]).prefix(44))
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*> `")) : e.title
            let exactRange = raw.range(of: first, options: [.caseInsensitive, .widthInsensitive])
            let conceptRange = related.lazy.compactMap {
              raw.range(of: $0, options: [.caseInsensitive, .widthInsensitive])
            }.first
            let range = exactRange ?? conceptRange
              ?? terms.filter { $0.count > 1 }.sorted { $0.count > $1.count }.lazy.compactMap {
                raw.range(of: $0, options: [.caseInsensitive, .widthInsensitive])
              }.first
            let reason: String
            if let conceptRange, exactRange == nil, !phrase.contains(AtlasSearchText.fold(String(raw[conceptRange]))) {
              reason = "相关词项匹配"
            } else {
              reason = range == nil ? "来源标题或类型匹配" : "原文词项匹配"
            }
            let middle = range?.lowerBound ?? raw.startIndex
            var begin = raw.index(middle, offsetBy: -56, limitedBy: raw.startIndex) ?? raw.startIndex
            if raw.count <= 300 {
              begin = raw.startIndex
            } else if begin != raw.startIndex,
              let boundary = raw[begin..<middle].firstIndex(where: {
                $0.isWhitespace || "。！？；".contains($0)
              })
            {
              begin = raw.index(after: boundary)
            }
            let previewEnd =
              raw.count <= 300
              ? raw.endIndex
              : raw.index(begin, offsetBy: 220, limitedBy: raw.endIndex) ?? raw.endIndex
            let end = max(previewEnd, range?.upperBound ?? previewEnd)
            let start = (r["start"] as Int) + raw[..<begin].unicodeScalars.count
            let snippet = String(raw[begin..<end])
            results.append(
              AtlasSearchHit(
                workspaceID: store.workspaceID, kind: e.kind, objectID: e.object,
                versionID: e.version, locator: r["locator"], title: title, detail: e.detail,
                text: snippet, sourceSHA: r["source_sha256"], start: start,
                end: start + snippet.unicodeScalars.count, ordinal: e.ordinal,
                matchStart: range.map {
                  (r["start"] as Int) + raw[..<$0.lowerBound].unicodeScalars.count
                },
                matchEnd: range.map {
                  (r["start"] as Int) + raw[..<$0.upperBound].unicodeScalars.count
                },
                reason: semantic ? "本机语义匹配" : reason))
          }
        }
        // Exact matching uses only the scoped chunks, including single characters and punctuation-rich code.
        let exactSQL = """
          SELECT c.id,c.source_reference_id FROM \(table)
          WHERE instr(c.folded,?)>0 OR instr(c.folded_title,?)>0
          ORDER BY c.folded_title=? DESC,instr(c.folded,?)>0 DESC,length(c.text),c.id
          """
        try appendMatches(exactSQL, arguments: [phrase, phrase, phrase, phrase])
        func alternatives(_ words: [String]) -> String {
          words.prefix(128).map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          }.joined(separator: " OR ")
        }
        func appendFullText(_ rankedTerms: [String], related: [String] = [], requiring groups: [[String]] = []) throws {
          let clauses = [alternatives(rankedTerms)] + groups.map(alternatives)
          let fts = clauses.map { "(" + $0 + ")" }.joined(separator: " AND ")
          try appendMatches(
            """
            SELECT c.id,c.source_reference_id FROM search_fts
            JOIN search_chunk c ON c.id=search_fts.rowid
            JOIN search_allowed a ON a.key=c.source_reference_id
            WHERE search_fts MATCH ? ORDER BY bm25(search_fts,3,1),c.id
            """,
            arguments: [fts], related: related)
        }
        let exactHit = !results.isEmpty
        if !exactHit, queries.count == 1 {
          let sentence = AtlasSearchText.sentenceTerms(first, literal: terms)
          let ranked = sentence.map { concepts + concepts + concepts + $0 } ?? (concepts + terms)
          // A passage matching multiple concepts outranks one matching only a common word.
          // Then fill from the ordinary scoped ranking, including partial matches.
          if groups.count > 1 { try appendFullText(ranked, related: concepts, requiring: groups) }
          if results.count < target && (sentence != nil || !concepts.isEmpty) {
            try appendFullText(ranked, related: concepts)
          }
        }
        if results.count < target && !terms.isEmpty { try appendFullText(terms) }
        if !exactHit, sentenceQuery, !byKey.isEmpty,
          let encoder = ChinesePassageSearch.shared {
          let ranked = try encoder.rankedChunks(query: first, lexical: selectedChunks, db: db)
          if let best = ranked.first {
            let lexical = results
            results.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)
            let list = String(decoding: try JSONEncoder().encode(ranked.map(\.chunk)), as: UTF8.self)
            try appendMatches("""
              SELECT c.id,c.source_reference_id FROM json_each(?) j JOIN search_chunk c ON c.id=j.value
              JOIN search_allowed a ON a.key=c.source_reference_id ORDER BY j.key
              """, arguments: [list], semantic: true)
            let semantic = results
            // Promote a new source only when it adds a clear semantic signal beyond the
            // lexical shortlist. Preserve its first two results and the best-supported remainder.
            let scores = Dictionary(ranked.compactMap { match -> (String, Float)? in
              guard let entity = byKey[match.key] else { return nil }
              return (entity.kind.rawValue + "|" + entity.object + "|" + entity.version, match.score)
            }, uniquingKeysWith: max)
            let shortlist = Array(lexical.prefix(5))
            var lead = shortlist
            if let candidate = semantic.first, !shortlist.contains(where: { $0.id == candidate.id }),
              best.score > (shortlist.compactMap { scores[$0.id] }.max() ?? -1) + 0.06 {
              if lead.count == 5 {
                let tail = (2..<5).reversed()
                let weakest = tail.min { (scores[lead[$0].id] ?? -1) < (scores[lead[$1].id] ?? -1) }
                if let weakest { lead.remove(at: weakest) }
              }
              lead.insert(candidate, at: min(2, lead.count))
            }
            seen.removeAll(keepingCapacity: true)
            let merged = lead + semantic.prefix(3) + lexical + semantic.prefix(8)
            return Array(merged.filter { seen.insert($0.id).inserted }.prefix(resultLimit))
          }
        }
        return Array(results.prefix(resultLimit))
      }
    }
  }
}
