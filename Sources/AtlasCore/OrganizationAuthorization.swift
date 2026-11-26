import Foundation
import GRDB

/// An optional local grant is an explicit subset of a project's placements, regions and operation types.
public struct OrganizationGrant: Codable, Equatable, Sendable {
  public let placements: [String], regions: [String], actions: [OrganizationAction]
}
public struct OrganizationDisposition: Codable, Equatable, Sendable {
  public let applied: String?, pending: String?
}
extension AtlasStore {
  public func organizationGrant() throws -> OrganizationGrant? {
    try database.read { db in try readOrganizationGrant(db) }
  }
  private func readOrganizationGrant(_ db: Database) throws -> OrganizationGrant? {
    try String.fetchOne(
      db, sql: "SELECT value_json FROM workspace_settings WHERE key='automation.permission.organization'"
    ).map { try organizationDecode(OrganizationGrant.self, $0) }
  }
  public func setOrganizationGrant(
    _ scope: OrganizationScope?, actions: Set<OrganizationAction> = []
  ) throws {
    try database.write { db in
      let grant: OrganizationGrant?
      if let scope {
        guard !actions.isEmpty, actions.isSubset(of: Set(scope.allowed)),
          Set(scope.objects.map(\.id)).count == scope.objects.count
        else { throw organizationError("授权超出所选动作或材料。") }
        for s in scope.objects {
          guard try organizationObject(db, s.id)?.target == s.target else {
            throw organizationError("授权材料已经改变。")
          }
        }
        grant = OrganizationGrant(
          placements: scope.objects.filter { o in actions.contains { scope.canEdit(o, action: $0) } }.map(\.id).sorted(), regions: scope.regions.map(\.id).sorted(),
          actions: actions.sorted { $0.rawValue < $1.rawValue })
      } else {
        grant = nil
      }
      if try readOrganizationGrant(db) == grant { return }
      if let grant {
        try db.execute(
          sql:
            "INSERT INTO workspace_settings VALUES('automation.permission.organization',?,1,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at",
          arguments: [try chatJSON(grant), orgStamp()])
      } else {
        try db.execute(sql: "DELETE FROM workspace_settings WHERE key='automation.permission.organization'")
      }
      try db.execute(
        sql:
          "UPDATE workspace SET policy_revision=policy_revision+1,updated_at=? WHERE singleton=1",
        arguments: [orgStamp()])
    }
  }
  /// The entire dependency component remains pending if an operation lacks a grant.
  /// A disjoint authorized component is separated and committed in the same database transaction.
  public func applyAuthorizedOrganization(_ id: String) throws -> OrganizationDisposition {
    try database.write { db in
      let ticket = "organization.auto." + id
      if let json = try String.fetchOne(
        db, sql: "SELECT result_json FROM command_receipt WHERE request_id=?", arguments: [ticket])
      {
        return try organizationDecode(OrganizationDisposition.self, json)
      }
      let p = try loadOrganization(db, id)
      if p.status == "applied" { return .init(applied: id, pending: nil) }
      guard p.status == "reviewable", let grant = try readOrganizationGrant(db) else {
        return .init(applied: nil, pending: id)
      }
      guard
        try Int.fetchOne(db, sql: "SELECT policy_revision FROM workspace WHERE singleton=1")
          == p.scope.policy
      else {
        try db.execute(sql: "UPDATE change_batch SET status='stale' WHERE id=?", arguments: [id])
        return .init(applied: nil, pending: id)
      }
      let placements = Set(grant.placements)
      let regions = Set(grant.regions)
      let actions = Set(grant.actions)
      var blocked = Set(
        p.edits.filter { e in
          !actions.contains(e.action) || !placements.contains(e.target)
            || (e.peer.map { !placements.contains($0) } ?? false)
            || (e.region.map { !regions.contains($0) } ?? false)
        }.map(\.id))
      var count: Int
      repeat {
        count = blocked.count
        for e in p.edits where blocked.contains(e.id) || !Set(e.requires).isDisjoint(with: blocked)
        {
          blocked.insert(e.id)
          blocked.formUnion(e.requires)
        }
      } while count != blocked.count
      let safe = p.edits.filter { !blocked.contains($0.id) }
      guard !safe.isEmpty else { return .init(applied: nil, pending: id) }
      let pending: String?
      let apply: String
      if blocked.isEmpty {
        apply = id
        pending = nil
      } else {
        apply = UUID().uuidString
        let wait = UUID().uuidString
        pending = wait
        let actor =
          try String.fetchOne(
            db, sql: "SELECT actor_kind FROM change_batch WHERE id=?", arguments: [id]) ?? "user"
        try recordOrganization(
          db, id: apply, scope: p.scope, edits: safe, title: p.summary + "（已授权范围）", actor: actor)
        try recordOrganization(
          db, id: wait, scope: p.scope, edits: p.edits.filter { blocked.contains($0.id) },
          title: p.summary + "（待决定范围）", actor: actor)
        try db.execute(
          sql: "UPDATE change_batch SET status='cancelled' WHERE id=?", arguments: [id])
      }
      if let error = try applyOrganizationInsideTransaction(db, apply) {
        if apply == id { return .init(applied: nil, pending: id) }
        throw organizationError(error)  // Roll back the split as well.
      }
      let result = OrganizationDisposition(applied: apply, pending: pending)
      try db.execute(
        sql: "INSERT INTO command_receipt VALUES(?,'organization.auto',?,?,?)",
        arguments: [ticket, chatDigest([id]), try chatJSON(result), orgStamp()])
      return result
    }
  }
}
