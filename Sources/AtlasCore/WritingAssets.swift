import Darwin
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

struct StagedAsset: Sendable {
  let hash: String
  let path: String
  let size: Int
  let mime: String
  func register(_ db: Database) throws {
    try db.execute(
      sql:
        "INSERT OR IGNORE INTO asset(sha256,byte_count,media_type,relative_path,created_at) VALUES (?,?,?,?,?)",
      arguments: [hash, size, mime, path, writingDate()])
  }
}

extension AtlasStore {
  func stageAsset(_ data: Data, mime: String, digest: String? = nil) throws -> StagedAsset {
    let hash = digest ?? atlasHash(data)
    let rel = "assets/\(hash.prefix(2))/\(hash)"
    let url = directory.appendingPathComponent(rel)
    let parent = url.deletingLastPathComponent()
    let fm = FileManager.default
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) {
      let tmp = directory.appendingPathComponent("tmp/" + writingID())
      defer { try? fm.removeItem(at: tmp) }
      try data.write(to: tmp, options: .withoutOverwriting)
      let handle = try FileHandle(forWritingTo: tmp)
      try handle.synchronize()
      try handle.close()
      guard atlasHash(try Data(contentsOf: tmp, options: .mappedIfSafe)) == hash else {
        throw AtlasStoreError.invalid("临时资产未通过校验。")
      }
      if link(tmp.path, url.path) != 0 && errno != EEXIST {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      defer { Darwin.close(fd) }
      guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    guard atlasHash(try Data(contentsOf: url, options: .mappedIfSafe)) == hash else {
      throw AtlasStoreError.invalid("已有资产未通过校验。")
    }
    return StagedAsset(hash: hash, path: rel, size: data.count, mime: mime)
  }
  public func writingImageLinks(version: String) throws -> [String: String] {
    try database.read { db in
      var result = [String: String]()
      for row in try Row.fetchAll(
        db,
        sql:
          "SELECT original_reference,asset_sha256 FROM document_asset WHERE document_version_id=? AND role='image'",
        arguments: [version])
      {
        result[row["original_reference"] as String] = row["asset_sha256"]
      }
      // Other aliases may address the same immutable bytes.
      if let raw = try String.fetchOne(
        db,
        sql:
          "SELECT json_extract(source_metadata_json,'$.image_aliases') FROM document_version WHERE id=?",
        arguments: [version]),
        let aliases = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
      {
        let allowed = Set(result.values)
        for (ref, digest) in aliases where allowed.contains(digest) { result[ref] = digest }
      }
      return result
    }
  }

  public func readWritingImage(hash: String, version: String) throws -> (Data, String) {
    guard hash.utf8.count == 64,
      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw AtlasStoreError.invalid("图像地址无效。") }
    let mime = try database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT a.media_type FROM document_asset d JOIN asset a ON d.asset_sha256=a.sha256 WHERE d.document_version_id=? AND a.sha256=? AND d.role='image'
          """, arguments: [version, hash])
    }
    guard let mime, ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else {
      throw AtlasStoreError.invalid("此版本未附带该图像。")
    }
    let data = try Data(
      contentsOf: directory.appendingPathComponent("assets/\(hash.prefix(2))/\(hash)"),
      options: .mappedIfSafe)
    guard atlasHash(data) == hash else { throw AtlasStoreError.invalid("图像内容未通过校验。") }
    return (data, mime)
  }

  func stageMarkdownImages(_ refs: Set<String>, beside url: URL) throws -> [String: StagedAsset] {
    let root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    var result = [String: StagedAsset]()
    for ref in refs {
      guard let components = URLComponents(string: ref), components.scheme == nil,
        components.host == nil,
        !components.path.isEmpty, !components.path.hasPrefix("/"),
        !components.path.contains("\u{0}")
      else { continue }
      let file = root.appendingPathComponent(components.path).resolvingSymlinksInPath()
        .standardizedFileURL
      guard file.pathComponents.starts(with: root.pathComponents),
        file.pathComponents.count > root.pathComponents.count,
        ["png", "jpg", "jpeg", "gif", "webp"].contains(file.pathExtension.lowercased()),
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
        let source = CGImageSourceCreateWithData(bytes as CFData, nil),
        let type = CGImageSourceGetType(source),
        let mime = UTType(type as String)?.preferredMIMEType,
        ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
      else { continue }
      result[ref] = try stageAsset(bytes, mime: mime)
    }
    return result
  }
}
