import AtlasIPC
import Foundation
import GRDB
import PDFKit

struct AgentPage {
  var rows: ArraySlice<AgentValue>
  var body: AgentBody? = nil
  let query: String, expires: Date
}

struct AgentBody {
  let source: SearchEntity
  var locators: ArraySlice<String>, offset: Int

  mutating func read(_ count: Int, store: AtlasStore, db: Database) throws -> [AgentValue] {
    var rows: [AgentValue] = []
    while rows.count < count, let loc = locators.first {
      guard let part = try store.searchParts(db, source, locator: loc).first else {
        locators = locators.dropFirst()
        offset = 0
        continue
      }
      let scalars = part.1.unicodeScalars
      var rest = scalars.dropFirst(offset)
      repeat {
        let chunk = rest.prefix(2048)
        let end = offset + chunk.count
        rows.append(
          .object([
            "id": .string(source.object), "kind": .string(source.kind.rawValue),
            "version": .string(source.version), "locator": .string(loc),
            "start": .number(Double(offset)), "end": .number(Double(end)),
            "text": .string(String(chunk)),
          ]))
        offset = end
        rest = rest.dropFirst(chunk.count)
      } while !rest.isEmpty && rows.count < count
      if rest.isEmpty {
        locators = locators.dropFirst()
        offset = 0
      }
    }
    return rows
  }
}

extension AtlasStore {
  fileprivate func agentLocators(_ db: Database, _ entity: SearchEntity) throws -> [String] {
    switch entity.kind {
    case .markdown:
      let ids = try String.fetchAll(
        db, sql: "SELECT id FROM document_block WHERE document_version_id=? ORDER BY ordinal",
        arguments: [entity.version])
      return ids.isEmpty ? ["body"] : ids
    case .pdf:
      guard let hash = entity.asset,
        let pdf = PDFDocument(
          url: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)")),
        !pdf.isEncrypted
      else { return [] }
      return (0..<pdf.pageCount).map { "p" + String($0) }
    default: return ["body"]
    }
  }
}
extension AtlasAgentService {
  func page(_ req: AgentRequest, _ store: AtlasStore, _ grant: AtlasAgentGrant) throws
    -> AgentValue
  {
    var p = req.params
    let cursor = p.removeValue(forKey: "cursor")?.text
    let limit = p["limit"]?.integer ?? 12
    guard (1...40).contains(limit) else { throw AgentFault.invalid }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let signature = chatDigest([req.method, String(decoding: try encoder.encode(p), as: UTF8.self)])
    var scope = AtlasSearchScope(permittedObjects: grant.objects)
    if let scopeParam = p["scope"] {
      let ids = try scopeParam.decoded(Set<String>.self)
      if let permitted = grant.objects, !ids.isSubset(of: permitted) { throw AgentFault.denied }
      scope.permittedObjects = ids
    }
    if let kind = p["kind"]?.text {
      guard let k = AtlasSearchKind(rawValue: kind) else { throw AgentFault.invalid }
      scope.kinds = [k]
    }
    let version = p["version"]?.text
    scope.includeHistory = grant.history && version != nil
    let now = Date()
    pages = pages.filter { $0.value.expires > now }
    var snapshot: AgentPage
    if let cursor {
      guard let previous = pages[cursor], previous.query == signature else {
        throw AgentFault("CURSOR_STALE", "分页游标已失效或查询发生变化。")
      }
      snapshot = previous
    } else if req.method == "read", let id = p["id"]?.text {
      if let permitted = scope.permittedObjects, !permitted.contains(id) { throw AgentFault.denied }
      scope.permittedObjects = [id]
      let body = try store.database.read { db -> AgentBody in
        guard let e = try store.searchEntities(db, scope: scope, version: version).first else {
          throw AgentFault.denied
        }
        return AgentBody(source: e, locators: try store.agentLocators(db, e)[...], offset: 0)
      }
      snapshot = AgentPage(
        rows: [], body: body, query: signature, expires: now.addingTimeInterval(180))
    } else {
      let rows: [AgentValue]
      if req.method == "search" {
        guard let query = p["query"]?.text, !query.isEmpty, query.count <= 2048 else {
          throw AgentFault.invalid
        }
        let hits = try AtlasSearchIndex(store: store).matches(query, scope: scope)
        rows = hits.filter { version == nil || $0.versionID == version }.map { h in
          .object([
            "id": .string(h.objectID), "kind": .string(h.kind.rawValue), "title": .string(h.title),
            "version": .string(h.versionID), "locator": .string(h.locator),
            "start": .number(Double(h.start)), "end": .number(Double(h.end)),
            "text": .string(h.text), "reason": .string(h.reason),
          ])
        }
      } else {
        rows = try store.database.read { db in
          let entities = try store.searchEntities(db, scope: scope, version: version).sorted {
            ($0.kind.rawValue, $0.object, $0.ordinal) < ($1.kind.rawValue, $1.object, $1.ordinal)
          }
          return try entities.map { e in
            let entries = try String.fetchAll(
              db,
              sql:
                "SELECT id FROM placement WHERE view_id='atlas' AND (content_id=? OR document_id=?) ORDER BY id",
              arguments: [e.object, e.object])
            return .object([
              "id": .string(e.object), "kind": .string(e.kind.rawValue), "title": .string(e.title),
              "version": .string(e.version), "placements": try .encoded(entries),
            ])
          }
        }
      }
      snapshot = AgentPage(rows: rows[...], query: signature, expires: now.addingTimeInterval(180))
    }
    var remaining: Bool
    let visible: [AgentValue]
    if var body = snapshot.body {
      scope.permittedObjects = [body.source.object]
      visible = try store.database.read { db in
        guard let live = try store.searchEntities(db, scope: scope).first,
          body.source.kind != .topic || live.version == body.source.version
        else { throw AgentFault("CURSOR_STALE", "分页对象已撤回或被移除。") }
        return try body.read(limit, store: store, db: db)
      }
      remaining = !body.locators.isEmpty
      snapshot.body = body
    } else {
      let live = Set(
        try store.database.read { db in try store.searchEntities(db, scope: scope).map(\.object) })
      visible = Array(snapshot.rows.prefix(limit))
      guard visible.allSatisfy({ $0.fields?["id"]?.text.map(live.contains) == true }) else {
        throw AgentFault("CURSOR_STALE", "分页对象已撤回或被移除。")
      }
      snapshot.rows = snapshot.rows.dropFirst(visible.count)
      remaining = !snapshot.rows.isEmpty
    }
    var next: AgentValue = .null
    if remaining {
      let key = UUID().uuidString
      if pages.count >= 32, let oldest = pages.min(by: { $0.value.expires < $1.value.expires })?.key
      {
        pages.removeValue(forKey: oldest)
      }
      pages[key] = snapshot
      next = .string(key)
    }
    return .object(["items": .list(Array(visible)), "next_cursor": next])
  }
}
