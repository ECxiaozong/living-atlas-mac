import CAtlasArchive
import Darwin
import Foundation

private let archiveChunk = 256 * 1024
private func archiveFailure(_ handle: OpaquePointer?) -> AtlasStoreError {
  .invalid(
    "ZIP 处理失败："
      + (handle.flatMap { archive_error_string($0) }.map { String(cString: $0) } ?? "未知错误"))
}
/// Seekable ZIP validates its central directory before any member is trusted. Only regular files enter the result.
struct ProjectZIP {
  let url: URL
  struct Member {
    let path: String
    let directory: Bool
    let size: Int
    fileprivate let reader: OpaquePointer
    func stream(_ update: (Data) throws -> Void) throws {
      var buffer = [UInt8](repeating: 0, count: archiveChunk)
      var total = 0
      while true {
        let n = archive_read_data(reader, &buffer, buffer.count)
        guard n >= 0 else { throw archiveFailure(reader) }
        if n == 0 { break }
        guard n <= size - total else { throw AtlasStoreError.invalid("解压长度超过目录记录：" + path) }
        total += n
        try update(Data(buffer[0..<n]))
      }
      guard total == size else { throw AtlasStoreError.invalid("ZIP 成员不完整：" + path) }
    }
  }
  func visit(_ read: (Member) throws -> Void) throws {
    guard let reader = archive_read_new() else { throw archiveFailure(nil) }
    defer { archive_read_free(reader) }
    guard archive_read_support_format_zip_seekable(reader) == 0,
      archive_read_open_filename(reader, url.path, archiveChunk) == 0
    else { throw archiveFailure(reader) }
    var seen = Set<String>()
    while true {
      var raw: OpaquePointer?
      let status = archive_read_next_header(reader, &raw)
      if status == 1 { break }
      guard status == 0, let e = raw, let name = archive_entry_pathname_utf8(e),
        let path = String(validatingCString: name)
      else { throw archiveFailure(reader) }
      let mode = archive_entry_filetype(e)
      let isDir = mode == mode_t(S_IFDIR)
      let sz = archive_entry_size(e)
      let plain = isDir && path.hasSuffix("/") ? String(path.dropLast()) : path
      guard mode == mode_t(S_IFREG) || isDir, archive_entry_is_encrypted(e) == 0,
        archive_entry_symlink(e) == nil, archive_entry_hardlink(e) == nil,
        archive_entry_size_is_set(e) != 0, sz >= 0, sz <= Int.max, plain.utf8.count <= 1024,
        !plain.isEmpty, !plain.hasPrefix("/"),
        !plain.contains("\\"), !plain.contains(":"),
        !plain.unicodeScalars.contains(where: { $0.value < 32 }),
        plain.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
          !$0.isEmpty && $0 != "." && $0 != ".."
        }),
        seen.insert(plain.precomposedStringWithCanonicalMapping).inserted
      else { throw AtlasStoreError.invalid("ZIP 路径、成员类型或长度无效：" + path) }
      try read(Member(path: plain, directory: isDir, size: Int(sz), reader: reader))
      guard archive_read_data_skip(reader) == 0 else { throw archiveFailure(reader) }
    }
  }

  static func write(_ files: [(String, URL)], to destination: URL, check: () throws -> Void) throws
  {
    guard let writer = archive_write_new() else { throw archiveFailure(nil) }
    defer { archive_write_free(writer) }
    guard archive_write_set_format_zip(writer) == 0,
      archive_write_open_filename(writer, destination.path) == 0
    else { throw archiveFailure(writer) }
    for (name, source) in files {
      guard let header = archive_entry_new() else { throw archiveFailure(writer) }
      defer { archive_entry_free(header) }
      let info = try source.resourceValues(forKeys: [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize else {
        throw AtlasStoreError.invalid("资产不可读：" + name)
      }
      archive_entry_set_pathname_utf8(header, name)
      archive_entry_set_filetype(header, UInt32(S_IFREG))
      archive_entry_set_perm(header, 0o600)
      archive_entry_set_size(header, Int64(size))
      guard archive_write_header(writer, header) == 0 else { throw archiveFailure(writer) }
      let input = try FileHandle(forReadingFrom: source)
      do {
        var total = 0
        while let bytes = try input.read(upToCount: archiveChunk), !bytes.isEmpty {
          try check()
          total += bytes.count
          let n = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
          guard n == bytes.count else { throw archiveFailure(writer) }
        }
        guard total == size else { throw AtlasStoreError.invalid("写入时资产长度发生变化：" + name) }
        try input.close()
      } catch {
        try? input.close()
        throw error
      }
      guard archive_write_finish_entry(writer) == 0 else { throw archiveFailure(writer) }
    }
    guard archive_write_close(writer) == 0 else { throw archiveFailure(writer) }
  }
}
