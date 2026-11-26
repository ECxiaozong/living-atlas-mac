import Foundation
import GRDB

public enum SheetObject: Equatable {
  case document(String)
  case turn(String)

  var id: String {
    switch self {
    case .document(let id), .turn(let id): return id
    }
  }
  var kind: String {
    switch self {
    case .document: return "document"
    case .turn: return "turn"
    }
  }
  public var placementID: String { "reading." + kind + "." + id }
}

extension AtlasStore {
  private static func ensureCanvas(_ db: Database) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO canvas_view(id,title) VALUES ('reading','阅读与追问')")
  }

  public func canvasZoom() throws -> Double {
    try database.read { db in
      try Double.fetchOne(db, sql: "SELECT zoom FROM canvas_view WHERE id='reading'") ?? 1
    }
  }

  public func setCanvasZoom(_ scale: Double) throws {
    guard scale.isFinite, (0.75...1.5).contains(scale) else {
      throw AtlasStoreError.invalid("图版缩放超出可用范围。")
    }
    try database.write { db in
      try Self.ensureCanvas(db)
      try db.execute(
        sql:
          "UPDATE canvas_view SET zoom=?,state_revision=state_revision+1 WHERE id='reading' AND zoom<>?",
        arguments: [scale, scale])
    }
  }

  public func sheetOrigin(_ target: SheetObject) throws -> CGPoint? {
    try database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT x,y FROM placement WHERE id=?", arguments: [target.placementID]
      )
      .map { CGPoint(x: $0["x"] as Double, y: $0["y"] as Double) }
    }
  }

  /// A finished drag is one command. Camera-only changes never create layout history.
  public func saveSheet<Value: Encodable>(
    _ state: Value, pane: String, camera: CGPoint, target: SheetObject?, from: CGPoint,
    frame: CGRect,
    requestID: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let stateJSON = String(decoding: try encoder.encode(state), as: UTF8.self)
    try database.write { db in
      try Self.ensureCanvas(db)
      if let target, from != frame.origin {
        let payload: [String: String] = [
          "width": String(Double(frame.width)), "height": String(Double(frame.height)),
          "placement": target.placementID, "fromX": String(Double(from.x)),
          "fromY": String(Double(from.y)),
          "toX": String(Double(frame.minX)), "toY": String(Double(frame.minY)),
        ]
        let digest = atlasHash(try encoder.encode(payload))
        if let prior = try String.fetchOne(
          db, sql: "SELECT payload_sha256 FROM command_receipt WHERE request_id=?",
          arguments: [requestID])
        {
          guard prior == digest else { throw AtlasStoreError.invalid("移动命令与已保存记录冲突。") }
          return
        }
        let before = String(
          decoding: try encoder.encode(["x": from.x, "y": from.y]), as: UTF8.self)
        let after = String(
          decoding: try encoder.encode(["x": frame.minX, "y": frame.minY]), as: UTF8.self)
        let stamp = Date.now.ISO8601Format()
        let revision =
          try Int.fetchOne(
            db, sql: "SELECT layout_revision FROM placement WHERE id=?",
            arguments: [target.placementID]) ?? 0
        try db.execute(
          sql: """
            INSERT INTO placement(id,view_id,target_kind,document_id,turn_id,x,y,width,height,display_mode)
            VALUES (?,'reading',?,?,?,?,?,?,?,'reading')
            ON CONFLICT(id) DO UPDATE SET x=excluded.x,y=excluded.y,width=excluded.width,height=excluded.height,layout_revision=layout_revision+1
            """,
          arguments: [
            target.placementID, target.kind, target.kind == "document" ? target.id : nil,
            target.kind == "turn" ? target.id : nil, frame.minX, frame.minY, frame.width,
            frame.height,
          ])
        let scope = String(decoding: try encoder.encode([target.placementID]), as: UTF8.self)
        let revisions = String(
          decoding: try encoder.encode([target.placementID: revision]), as: UTF8.self)
        try db.execute(
          sql: """
            INSERT INTO change_batch(id,status,actor_kind,read_scope_json,write_scope_json,base_revisions_json,policy_revision_at_plan,summary,created_at,applied_at)
            VALUES (?,'applied','user',?,?,?,1,'移动图版',?,?)
            """, arguments: [requestID, scope, scope, revisions, stamp, stamp])
        try db.execute(
          sql: """
            INSERT INTO change_operation(id,batch_id,ordinal,operation_type,target_kind,target_id,facet,expected_revision,before_json,after_json)
            VALUES (?,?,0,'move','placement',?,'layout',?,?,?)
            """,
          arguments: [UUID().uuidString, requestID, target.placementID, revision, before, after])
        try db.execute(
          sql: """
            INSERT INTO command_receipt(request_id,command_type,payload_sha256,result_json,committed_at)
            VALUES (?,'MovePlacements',?,json_object('batch_id',?,'placement_id',?,'revision',?),?)
            """, arguments: [requestID, digest, requestID, target.placementID, revision + 1, stamp])
      }
      if pane == "library" {
        try db.execute(
          sql:
            "UPDATE canvas_view SET camera_x=?,camera_y=?,state_revision=state_revision+1 WHERE id='reading' AND (camera_x<>? OR camera_y<>?)",
          arguments: [camera.x, camera.y, camera.x, camera.y])
      }
      try db.execute(
        sql: """
          INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES(?,?,1,?)
          ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at
          """, arguments: ["view.canvas." + pane, stateJSON, Date.now.ISO8601Format()])
    }
  }
}
