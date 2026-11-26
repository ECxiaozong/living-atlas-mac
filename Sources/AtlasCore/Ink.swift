import Darwin
import Foundation
import GRDB
import ImageIO
import PDFKit

public struct InkPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct InkSurface: Identifiable, Equatable, Sendable {
  public let id: String
  public let versionID: String
  public let version: Int
  public let page: Int?
  public let width: Double
  public let height: Double
  public let rotation: Int
  public let minX: Double
  public let minY: Double
  public let snapshotHash: String?
}

public struct InkPath: Identifiable, Equatable, Sendable {
  public let id: String
  public let points: [InkPoint]
  public let width: Double
}

public struct InkViewport: Codable, Sendable {
  public var scrollX: Double
  public var scrollY: Double
  public var firstBlock: Int?
  public var lastBlock: Int?
  public var textFont: String
  public init(scrollX: Double, scrollY: Double, firstBlock: Int?, lastBlock: Int?, textFont: String)
  {
    self.scrollX = scrollX
    self.scrollY = scrollY
    self.firstBlock = firstBlock
    self.lastBlock = lastBlock
    self.textFont = textFont
  }
}

extension AtlasStore {
  private static let surfaceRows = """
    SELECT s.id,s.document_version_id AS vid,s.page_index,s.width,s.height,s.rotation_degrees,s.snapshot_asset_sha256,
    COALESCE(json_extract(s.layout_json,'$.minX'),0) AS x,COALESCE(json_extract(s.layout_json,'$.minY'),0) AS y,v.ordinal,v.document_id
    FROM annotation_surface s JOIN document_version v ON v.id=s.document_version_id
    """
  private static func inkSurface(_ row: Row) -> InkSurface {
    InkSurface(
      id: row["id"], versionID: row["vid"], version: row["ordinal"], page: row["page_index"],
      width: row["width"], height: row["height"],
      rotation: row["rotation_degrees"], minX: row["x"], minY: row["y"],
      snapshotHash: row["snapshot_asset_sha256"])
  }
  public func inkSurfaces(document: String) throws -> [InkSurface] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: Self.surfaceRows + " WHERE v.document_id=? ORDER BY s.rowid DESC",
        arguments: [document]
      ).map(Self.inkSurface)
    }
  }
  private static func requiredSurface(_ db: Database, id: String) throws -> InkSurface {
    guard let row = try Row.fetchOne(db, sql: surfaceRows + " WHERE s.id=?", arguments: [id]) else {
      throw AtlasStoreError.invalid("墨迹版面不可用。")
    }
    return inkSurface(row)
  }

  public func pdfInkSurface(version: String, page: Int) throws -> InkSurface {
    let file = try pdf(versionID: version)
    let pdf = try readablePDF(file)
    guard page >= 0, page < pdf.pageCount, let p = pdf.page(at: page) else {
      throw AtlasStoreError.invalid("PDF 页码无效。")
    }
    let box = p.bounds(for: .cropBox)
    return try database.write { db in
      if let existing = try Row.fetchOne(
        db, sql: Self.surfaceRows + " WHERE s.document_version_id=? AND s.page_index=?",
        arguments: [version, page])
      {
        return Self.inkSurface(existing)
      }
      let id = writingID()
      try db.execute(
        sql: """
          INSERT INTO annotation_surface(id,document_version_id,kind,page_index,width,height,rotation_degrees,coordinate_origin,layout_json,created_at)
          VALUES (?,?,'pdf_page',?,?,?,?,'pdf_page',?,?)
          """,
        arguments: [
          id, version, page, box.width, box.height, ((p.rotation % 360) + 360) % 360,
          try writingJSON(["minX": box.minX, "minY": box.minY]), writingDate(),
        ])
      return try Self.requiredSurface(db, id: id)
    }
  }

  public func markdownInkSurface(
    version: String, png: Data, width: Double, height: Double, viewport: InkViewport
  ) throws -> InkSurface {
    guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 32768, height <= 32768,
      viewport.scrollX.isFinite, viewport.scrollY.isFinite,
      let src = CGImageSourceCreateWithData(png as CFData, nil),
      CGImageSourceGetType(src) as String? == "public.png",
      CGImageSourceGetCount(src) == 1, CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    else { throw AtlasStoreError.invalid("无法保存这张 Markdown 版面。") }
    guard
      try database.read({ db in
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM document_version v JOIN document d ON d.id=v.document_id WHERE v.id=? AND d.kind='markdown')
            """, arguments: [version]) == true
      })
    else { throw AtlasStoreError.invalid("需要实际的 Markdown 正式版本。") }
    let asset = try stageAsset(png, mime: "image/png")
    return try database.write { db in
      let id = writingID()
      let stamp = writingDate()
      try asset.register(db)
      try db.execute(
        sql: """
          INSERT INTO annotation_surface(id,document_version_id,kind,width,height,coordinate_origin,snapshot_asset_sha256,layout_json,created_at)
          VALUES (?,?,'markdown_snapshot',?,?,'top_left',?,?,?)
          """,
        arguments: [id, version, width, height, asset.hash, try writingJSON(viewport), stamp])
      return try Self.requiredSurface(db, id: id)
    }
  }

  public func snapshotData(_ surface: InkSurface) throws -> Data {
    guard let hash = surface.snapshotHash, hash.utf8.count == 64,
      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AtlasStoreError.invalid("该版面没有快照。") }
    let data = try Data(
      contentsOf: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)"))
    guard atlasHash(data) == hash else { throw AtlasStoreError.invalid("版面资产校验失败。") }
    return data
  }
  public func inkPaths(surface: String) throws -> [InkPath] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.id,s.points_json,s.base_width FROM annotation a JOIN annotation_version v ON v.id=a.current_version_id
          JOIN ink_stroke s ON s.annotation_version_id=v.id WHERE v.surface_id=? AND a.deleted_at IS NULL ORDER BY a.rowid,s.ordinal
          """, arguments: [surface]
      ).map { r in
        InkPath(
          id: r["id"],
          points: try JSONDecoder().decode(
            [InkPoint].self, from: Data((r["points_json"] as String).utf8)), width: r["base_width"])
      }
    }
  }
  @discardableResult
  public func addInk(surface: String, points: [InkPoint], width: Double = 2.2) throws -> InkPath {
    try database.write { db in
      let layout = try Self.requiredSurface(db, id: surface)
      guard !points.isEmpty, width.isFinite, width > 0, width < 10000,
        points.allSatisfy({ p in
          p.x.isFinite && p.y.isFinite && p.x >= layout.minX && p.y >= layout.minY
            && p.x <= layout.minX + layout.width && p.y <= layout.minY + layout.height
        })
      else { throw AtlasStoreError.invalid("笔迹超出版面或坐标无效。") }
      let ref = writingID()
      let id = writingID()
      let revision = writingID()
      let stamp = writingDate()
      try db.execute(
        sql:
          "INSERT INTO reference_snapshot(id,source_kind,document_version_id,created_at) VALUES (?,'document',?,?)",
        arguments: [ref, layout.versionID, stamp])
      try db.execute(
        sql:
          "INSERT INTO source_anchor(id,reference_id,segment_order,page_index,selector_type,geometry_json) VALUES (?,?,0,?,?,?)",
        arguments: [
          writingID(), ref, layout.page, layout.page == nil ? "whole" : "page",
          try writingJSON(["surface_id": layout.id]),
        ])
      try db.execute(
        sql:
          "INSERT INTO annotation(id,document_id,current_version_id,created_at) SELECT ?,document_id,?,? FROM document_version WHERE id=?",
        arguments: [id, revision, stamp, layout.versionID])
      try db.execute(
        sql:
          "INSERT INTO annotation_version(id,annotation_id,ordinal,source_reference_id,surface_id,kind,created_at) VALUES (?,?,1,?,?,'ink',?)",
        arguments: [revision, id, ref, surface, stamp])
      try db.execute(
        sql:
          "INSERT INTO ink_stroke(id,annotation_version_id,ordinal,tool,color_token,base_width,points_json,created_at) VALUES (?,?,0,'pen','ink.primary',?,?,?)",
        arguments: [writingID(), revision, width, try writingJSON(points), stamp])
      return InkPath(id: id, points: points, width: width)
    }
  }
  public func setInkRemoved(_ id: String, surface: String, removed: Bool) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE annotation SET deleted_at=?,revision=revision+1 WHERE id=? AND (deleted_at IS NULL)=? AND
          EXISTS(SELECT 1 FROM annotation_version v WHERE v.id=annotation.current_version_id AND v.kind='ink' AND v.surface_id=?)
          """, arguments: [removed ? writingDate() : nil, id, removed, surface])
      guard db.changesCount == 1 else { throw AtlasStoreError.invalid("这笔墨迹已变更，请重开版面。") }
    }
  }
}
