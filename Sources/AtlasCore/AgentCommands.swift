import AtlasIPC
import Foundation
import GRDB

extension Notification.Name {
  public static let atlasAgentCommitted = Notification.Name("LivingAtlas.agentCommitted")
}
extension AtlasStore {
  public struct AgentObjectOption: Identifiable, Sendable {
    public let id, title, kind: String
  }
  public func agentObjectOptions() throws -> [AgentObjectOption] {
    try database.read { db in
      try searchEntities(db, scope: .init()).map {
        .init(
          id: $0.object, title: $0.title.isEmpty ? $0.kind.label : $0.title, kind: $0.kind.label)
      }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
  }
}

extension AtlasAgentService {
  func dispatch(_ req: AgentRequest, store: AtlasStore, grant: AtlasAgentGrant) throws -> AgentValue
  {
    let params = req.params
    let id = params["id"]?.text
    let supported: [String: Set<String>] = [
      "workspace.list": [], "read": ["scope", "kind", "version", "id", "limit", "cursor"],
      "search": ["scope", "kind", "version", "query", "limit", "cursor"],
      "content.create": ["kind", "body"],
      "proposal.submit": ["title", "placements", "regions", "edits"],
      "batch.diff": ["id", "offset", "limit"],
      "batch.apply": ["id"], "batch.rollback": ["id"],
    ]
    guard let fields = supported[req.method] else { throw AgentFault("UNKNOWN_COMMAND", "此命令未开放。") }
    guard Set(params.keys).isSubset(of: fields) else { throw AgentFault.invalid }
    if req.method == "workspace.list" {
      let title = try store.database.read { db in
        try String.fetchOne(
          db, sql: "SELECT title FROM workspace WHERE id=?", arguments: [store.workspaceID]) ?? ""
      }
      return .object([
        "workspaces": .list([
          .object([
            "id": .string(store.workspaceID), "title": .string(title), "state": .string("open"),
          ])
        ])
      ])
    }
    if ["read", "search"].contains(req.method) { return try page(req, store, grant) }
    if req.method == "content.create" {
      guard grant.create else { throw AgentFault.denied }
      guard params["kind"]?.text ?? "idea" == "idea", let raw = params["body"]?.text,
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.utf8.count <= 262144
      else { throw AgentFault.invalid }
      return try mutate(
        req, store,
        check: { _, value, issuer in
          // Create does not authorize reading the result of another scope's earlier request.
          guard let id = value.fields?["id"]?.text else { throw AgentFault.denied }
          if let allowed = grant.objects, !allowed.contains(id) {
            guard let issuer, issuer == self.grantID else { throw AgentFault.denied }
          }
        }
      ) { db in
        let item = try store.createAgentIdea(
          raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n"), db: db)
        return .object([
          "id": .string(item.id), "version": .string(item.currentVersionID!),
          "kind": .string("idea"),
        ])
      }
    }
    if req.method == "proposal.submit" {
      guard grant.propose else { throw AgentFault.denied }
      guard let selection = params["placements"], let changes = params["edits"],
        let title = params["title"]?.text, !title.isEmpty, title.count <= 240
      else { throw AgentFault.invalid }
      let placements = try selection.decoded(Set<String>.self)
      let regions = try params["regions"]?.decoded(Set<String>.self) ?? []
      let edits = try changes.decoded([OrganizationEdit].self)
      guard !placements.isEmpty, placements.count <= 64, regions.count <= 16, !edits.isEmpty,
        edits.count <= 64
      else { throw AgentFault.invalid }
      let ids = try store.database.read { db in try allowedScope(store: store, db: db, grant: grant)
      }
      guard placements.isSubset(of: ids.placements), regions.isSubset(of: ids.regions) else {
        throw AgentFault.denied
      }
      let scope = try store.organizationScope(
        placements: placements, regions: regions, allowed: Array(Set(edits.map(\.action))))
      return try mutate(req, store) { db in
        try store.verifyOrganization(scope, edits)
        let id = UUID().uuidString
        try store.recordOrganization(
          db, id: id, scope: scope, edits: edits, title: title, actor: "cli")
        return .object(["id": .string(id), "status": .string("reviewable")])
      }
    }
    guard ["batch.diff", "batch.apply", "batch.rollback"].contains(req.method) else {
      throw AgentFault("UNKNOWN_COMMAND", "此命令未开放。")
    }
    guard let id, !id.isEmpty else { throw AgentFault.invalid }
    let authorizedPlan: (Database) throws -> OrganizationPlan = { db in
      let plan: OrganizationPlan
      do { plan = try store.loadOrganization(db, id) } catch { throw AgentFault.denied }
      let allowed = try self.allowedScope(store: store, db: db, grant: grant)
      // Compare frozen target identities too: a removed placement must not grant access to another target.
      let permitted = plan.scope.objects.allSatisfy { o in
        if o.kind != "turn" { return allowed.objects.contains(o.target) }
        guard
          let row = try? Row.fetchOne(
            db, sql: "SELECT question_node_id,answer_node_id FROM inquiry_turn WHERE id=?",
            arguments: [o.target])
        else { return false }
        return ["question_node_id", "answer_node_id"].compactMap { row[$0] as String? }.allSatisfy(
          allowed.objects.contains)
      }
      guard permitted, Set(plan.scope.regions.map(\.id)).isSubset(of: allowed.regions) else {
        throw AgentFault.denied
      }
      if req.method != "batch.diff" {
        let permittedAction = req.method == "batch.apply" ? grant.apply : grant.rollback
        guard permittedAction,
          grant.removeEntrance || !plan.edits.contains(where: { $0.action == .removeEntrance })
        else {
          throw AgentFault("approval_required", "请在本机应用中审批批次 " + id)
        }
      }
      return plan
    }
    let run: (Database) throws -> AgentValue = { db in
      let plan = try authorizedPlan(db)
      if req.method == "batch.diff" {
        let offset = params["offset"]?.integer ?? 0
        let limit = params["limit"]?.integer ?? 12
        guard (0...plan.edits.count).contains(offset), (1...64).contains(limit) else {
          throw AgentFault.invalid
        }
        let items = try plan.edits.dropFirst(offset).prefix(limit).map { e -> AgentValue in
          guard let original = plan.scope.objects.first(where: { $0.id == e.target }) else {
            throw AgentFault.invalid
          }
          var from: [String: AgentValue] = [
            "version": .string(original.version), "title": .string(original.title),
          ]
          switch e.action {
          case .move, .addEntrance, .removeEntrance:
            from["x"] = .number(original.x)
            from["y"] = .number(original.y)
            from["region"] = original.region.map(AgentValue.string) ?? .null
          case .rewrite: from["body"] = .string(original.body)
          case .relate:
            from["links"] = try .encoded(
              plan.scope.links.filter { $0.from == e.target || $0.to == e.target })
          }
          return .object(["before": .object(from), "after": try .encoded(e)])
        }
        return .object([
          "id": .string(id), "title": .string(plan.summary), "status": .string(plan.status),
          "items": .list(items),
          "next_offset": offset + items.count < plan.edits.count
            ? .number(Double(offset + items.count)) : .null,
        ])
      }
      // Recheck policy, forward revisions and reverse dependencies in the same database transaction.
      if req.method == "batch.apply" {
        if (try store.applyOrganizationInsideTransaction(db, id)) != nil {
          throw AgentFault("VERSION_CONFLICT", "批次依据已经变化。")
        }
      } else {
        do { _ = try store.undoOrganizationInsideTransaction(db, id, actor: "cli") } catch {
          throw AgentFault("VERSION_CONFLICT", "该批次仍有依赖或已发生修改。")
        }
      }
      return .object([
        "id": .string(id), "status": .string(try store.loadOrganization(db, id).status),
      ])
    }
    if req.method == "batch.diff" { return try store.database.read(run) }
    return try mutate(req, store, check: { db, _, _ in _ = try authorizedPlan(db) }, run)
  }

  private func allowedScope(store: AtlasStore, db: Database, grant: AtlasAgentGrant) throws -> (
    objects: Set<String>, placements: Set<String>, regions: Set<String>
  ) {
    let objects = Set(
      try store.searchEntities(db, scope: .init(permittedObjects: grant.objects)).map(\.object))
    var placements = Set<String>()
    for r in try Row.fetchAll(
      db,
      sql:
        "SELECT p.id,p.content_id,p.document_id,t.question_node_id,t.answer_node_id FROM placement p LEFT JOIN inquiry_turn t ON t.id=p.turn_id WHERE p.view_id='atlas'"
    ) {
      let sources: [String] = ["content_id", "document_id", "question_node_id", "answer_node_id"]
        .compactMap { r[$0] as String? }
      if !sources.isEmpty, Set(sources).isSubset(of: objects) { placements.insert(r["id"]) }
    }
    let regions = Set(
      try Row.fetchAll(db, sql: "SELECT id,topic_id FROM region WHERE view_id='atlas'").compactMap {
        r in objects.contains(r["topic_id"] as String) ? r["id"] as String : nil
      })
    return (objects, placements, regions)
  }

  private func mutate(
    _ req: AgentRequest, _ store: AtlasStore,
    check: (Database, AgentValue, String?) throws -> Void = { _, _, _ in },
    _ operation: (Database) throws -> AgentValue
  ) throws -> AgentValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = chatDigest([
      store.workspaceID, req.method,
      String(decoding: try encoder.encode(req.params), as: UTF8.self),
    ])
    // Retries with the same ID cannot duplicate a write after credential rotation.
    let key = "agent." + chatDigest([store.workspaceID, req.requestID])
    let (result, didWrite) = try store.database.write { db -> (AgentValue, Bool) in
      if let receipt = try Row.fetchOne(
        db, sql: "SELECT payload_sha256,result_json FROM command_receipt WHERE request_id=?",
        arguments: [key])
      {
        guard (receipt["payload_sha256"] as String) == digest else {
          throw AgentFault("REQUEST_CONFLICT", "该 request_id 已绑定不同载荷。")
        }
        let saved = try JSONDecoder().decode(
          AgentValue.self, from: Data((receipt["result_json"] as String).utf8))
        let value = saved.fields?["result"] ?? saved
        try check(db, value, saved.fields?["grant_generation"]?.text)
        return (value, false)
      }
      let value = try operation(db)
      // Public audit generation distinguishes the creating grant without storing a token or token digest.
      let receipt = AgentValue.object([
        "grant_generation": grantID.map(AgentValue.string) ?? .null, "result": value,
      ])
      try db.execute(
        sql: "INSERT INTO command_receipt VALUES (?,?,?,?,?)",
        arguments: [
          key, "agent." + req.method, digest,
          String(decoding: try encoder.encode(receipt), as: UTF8.self), orgStamp(),
        ])
      return (value, true)
    }
    if didWrite {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: .atlasAgentCommitted, object: store, userInfo: ["method": req.method])
      }
    }
    return result
  }

}
