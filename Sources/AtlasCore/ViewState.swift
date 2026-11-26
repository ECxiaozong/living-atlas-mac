import Foundation
import GRDB

extension AtlasStore {
  public func readViewState<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
    try database.read { db in
      guard
        let string = try String.fetchOne(
          db, sql: "SELECT value_json FROM workspace_settings WHERE key=?",
          arguments: ["view." + key])
      else { return nil }
      return try JSONDecoder().decode(type, from: Data(string.utf8))
    }
  }

  public func saveViewState<Value: Encodable>(_ value: Value, key: String) throws {
    let string = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    try database.write { db in try Self.writeViewState(db, key: key, json: string) }
  }

  static func writeViewState(_ db: Database, key: String, json: String) throws {
    try db.execute(
        sql: """
          INSERT INTO workspace_settings(key,value_json,revision,updated_at) VALUES(?,?,1,?)
          ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,revision=revision+1,updated_at=excluded.updated_at
          """, arguments: ["view." + key, json, Date.now.ISO8601Format()])
  }
}
