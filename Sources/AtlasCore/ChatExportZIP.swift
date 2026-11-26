import Foundation
import zlib

/// Reads standard ZIP members in memory. Nothing in an export is executed or extracted to a filesystem path.
struct ChatExportZIP {
  struct Member {
    let name: String
    let method: Int
    let crc: UInt32
    let compressed: Int
    let expanded: Int
    let offset: Int
    let directory: Bool
  }
  let data: Data
  let members: [Member]
  private let centralOffset: Int
  static let maxJSONBytes = 512 * 1024 * 1024

  init(_ data: Data) throws {
    self.data = data
    guard data.count >= 22 else { throw ChatImportError("ZIP 目录不完整。") }
    let lower = max(0, data.count - 65_557)
    guard
      let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
        data.u32($0) == 0x0605_4b50 && $0 + 22 + data.u16($0 + 20) == data.count
      })
    else { throw ChatImportError("ZIP 尾部目录损坏。") }
    let count = data.u16(end + 10)
    let length = Int(data.u32(end + 12))
    let start = Int(data.u32(end + 16))
    guard data.u16(end + 4) == 0, data.u16(end + 6) == 0, data.u16(end + 8) == count,
      count < 65_535, start + length == end
    else { throw ChatImportError("无法读取分盘、ZIP64 或损坏的目录。") }
    centralOffset = start
    var entries: [Member] = []
    var names = Set<String>()
    var pos = start
    var expandedTotal = 0
    for _ in 0..<count {
      guard pos + 46 <= end, data.u32(pos) == 0x0201_4b50 else {
        throw ChatImportError("ZIP 成员目录损坏。")
      }
      let nameSize = data.u16(pos + 28)
      let next = pos + 46 + nameSize + data.u16(pos + 30) + data.u16(pos + 32)
      guard next <= end,
        let name = String(data: data[pos + 46..<pos + 46 + nameSize], encoding: .utf8)
      else {
        throw ChatImportError("ZIP 包含无法识别的文件名。")
      }
      let directory = name.hasSuffix("/")
      let parts = name.split(separator: "/", omittingEmptySubsequences: false)
      let segments = directory ? Array(parts.dropLast()) : Array(parts)
      let mode = Int(data.u32(pos + 38) >> 16) & 0xf000
      guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
        !name.unicodeScalars.contains(where: { $0.value < 32 }),
        !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
        names.insert(name.precomposedStringWithCanonicalMapping).inserted,
        [0, 0x4000, 0x8000].contains(mode)
      else { throw ChatImportError("ZIP 路径、链接或重复成员无法接受：\(name)") }
      let expanded = Int(data.u32(pos + 24))
      let compressed = Int(data.u32(pos + 20))
      guard data.u16(pos + 34) == 0, data.u16(pos + 8) & 1 == 0,
        expanded != 0xffff_ffff, compressed != 0xffff_ffff
      else { throw ChatImportError("不支持的加密或 ZIP64 成员：\(name)") }
      expandedTotal += expanded
      guard expandedTotal <= 4 * 1024 * 1024 * 1024, expanded <= Self.maxJSONBytes else {
        throw ChatImportError("ZIP 超出解压限制（总量 4 GiB、单成员 512 MiB）：\(name)")
      }
      entries.append(
        Member(
          name: name, method: data.u16(pos + 10), crc: data.u32(pos + 16), compressed: compressed,
          expanded: expanded, offset: Int(data.u32(pos + 42)), directory: directory))
      pos = next
    }
    guard pos == end else { throw ChatImportError("ZIP 目录长度不一致。") }
    members = entries
  }

  func bytes(_ item: Member) throws -> Data {
    let p = item.offset
    func bad(_ reason: String) -> ChatImportError { ChatImportError("\(item.name)：\(reason)") }
    guard item.expanded <= Self.maxJSONBytes, p + 30 <= centralOffset, data.u32(p) == 0x0403_4b50
    else {
      throw bad("文件头损坏或超出单个成员 512 MiB 限制。")
    }
    let nl = data.u16(p + 26)
    let start = p + 30 + nl + data.u16(p + 28)
    guard start + item.compressed <= centralOffset,
      String(data: data[(p + 30)..<(p + 30 + nl)], encoding: .utf8) == item.name,
      data.u16(p + 8) == item.method, data.u16(p + 6) & 1 == 0
    else { throw bad("成员头与目录不一致。") }
    let input = data.subdata(in: start..<start + item.compressed)
    let output: Data
    switch item.method {
    case 0: output = input
    case 8:
      var stream = z_stream()
      guard
        inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
      else {
        throw bad("无法初始化解压缩。")
      }
      defer { inflateEnd(&stream) }
      var buffer = Data(count: max(1, item.expanded))
      let status = input.withUnsafeBytes { source in
        buffer.withUnsafeMutableBytes { dest -> Int32 in
          stream.next_in = UnsafeMutablePointer(
            mutating: source.bindMemory(to: UInt8.self).baseAddress)
          stream.avail_in = uInt(source.count)
          stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress
          stream.avail_out = uInt(dest.count)
          return inflate(&stream, Z_FINISH)
        }
      }
      guard status == Z_STREAM_END, stream.total_out == item.expanded,
        stream.total_in == item.compressed
      else {
        throw bad("压缩数据不完整或解压长度不一致。")
      }
      output = item.expanded == 0 ? Data() : buffer
    default: throw bad("不支持此压缩方法。")
    }
    guard output.count == item.expanded,
      output.withUnsafeBytes({ crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
      ) == item.crc
    else {
      throw bad("大小或 CRC 校验失败。")
    }
    return output
  }
}

extension Data {
  fileprivate func u16(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
  fileprivate func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}

extension ChatExportZIP {
  /// A selected export directory has no single original file. Archive regular members byte-for-byte,
  /// with deterministic names and metadata so reopening the same export reuses its asset.
  static func directorySnapshot(_ root: URL) throws -> Data {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    var error: Error?
    guard
      let walker = fm.enumerator(
        at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
        errorHandler: { _, failure in
          error = failure
          return false
        })
    else {
      throw ChatImportError("无法读取所选导出目录。")
    }
    var files: [(String, URL)] = []
    let rootCount = root.standardizedFileURL.pathComponents.count
    for case let url as URL in walker {
      let info = try url.resourceValues(forKeys: keys)
      guard info.isSymbolicLink != true else {
        throw ChatImportError("目录中包含链接：" + url.lastPathComponent)
      }
      if info.isDirectory == true { continue }
      let name = url.standardizedFileURL.pathComponents.dropFirst(rootCount).joined(separator: "/")
      guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= maxJSONBytes,
        files.count < 65_534, name.utf8.count < 65_535
      else {
        throw ChatImportError("无法归档目录成员：" + name)
      }
      files.append((name, url))
    }
    if let error { throw error }
    guard files.contains(where: { $0.0.lowercased().hasSuffix(".json") }) else {
      throw ChatImportError("目录中没有 JSON 文件。")
    }
    var payload = Data()
    var central = Data()
    let limit = 1024 * 1024 * 1024
    for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
      let name = Data(relative.utf8)
      let source = try Data(contentsOf: url, options: .mappedIfSafe)
      guard source.count <= maxJSONBytes,
        payload.count + central.count + 76 + name.count * 2 + source.count + 22 <= limit
      else {
        throw ChatImportError("归档目录超过 1 GiB，或成员超过 512 MiB：" + relative)
      }
      let size = UInt32(source.count)
      let offset = UInt32(payload.count)
      let crc = source.withUnsafeBytes {
        UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)))
      }
      var record = Data()
      for value: UInt16 in [20, 0x800, 0, 0, 0x21] { record.chatInteger(value) }
      for value in [crc, size, size] { record.chatInteger(value) }
      record.chatInteger(UInt16(name.count))
      record.chatInteger(UInt16(0))
      payload.chatInteger(UInt32(0x0403_4b50))
      payload.append(record)
      payload.append(name)
      payload.append(source)
      central.chatInteger(UInt32(0x0201_4b50))
      central.chatInteger(UInt16(20))
      central.append(record)
      for _ in 0..<3 { central.chatInteger(UInt16(0)) }
      central.chatInteger(UInt32(0))
      central.chatInteger(offset)
      central.append(name)
    }
    let start = UInt32(payload.count)
    payload.append(central)
    payload.chatInteger(UInt32(0x0605_4b50))
    for value in [0, 0, files.count, files.count] { payload.chatInteger(UInt16(value)) }
    payload.chatInteger(UInt32(central.count))
    payload.chatInteger(start)
    payload.chatInteger(UInt16(0))
    return payload
  }
}

extension Data {
  fileprivate mutating func chatInteger<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }
}
