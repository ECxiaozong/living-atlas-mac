import CoreFoundation
import Foundation

public struct ChatImportError: LocalizedError, Sendable {
  public let message: String
  public var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

public struct ChatRawLocation: Codable, Equatable, Sendable {
  public let member: String?
  /// RFC 6901 pointer within this JSON member. The empty pointer denotes the complete pasted text.
  public let pointer: String
}
public struct ChatContentPart: Codable, Equatable, Sendable {
  public let kind: String
  public let text: String?
  public let attachment: String?
  public var archiveMember: String? = nil
  public var attachmentSHA256: String? = nil
  public let status: String
  public let index: Int
}
public struct ChatParsedMessage: Sendable {
  public let externalID: String?
  public let role: String
  public let roleRaw: String?
  public let timestamp: String?
  public let parent: String?
  public let body: String
  public let parts: [ChatContentPart]
  public let location: ChatRawLocation
  let digest: String
}
public struct ChatParsedConversation: Identifiable, Sendable {
  public let id: String
  public let externalID: String?
  public let title: String
  public var sourceCreated: String? = nil
  public var sourceModified: String? = nil
  public var currentNode: String? = nil
  public let location: ChatRawLocation
  public let messages: [ChatParsedMessage]
  public var branchCount: Int {
    Dictionary(grouping: messages.compactMap(\.parent), by: { $0 }).values.reduce(0) {
      $0 + max(0, $1.count - 1)
    }
  }
  public var attachmentCount: Int { messages.flatMap(\.parts).filter { $0.kind != "text" }.count }
}
public struct ChatImportPreview: Sendable {
  public let filename: String
  public let namespace: String
  public let sha256: String
  public let provider: String
  public let conversations: [ChatParsedConversation]
  public let diagnostics: [String]
  let bytes: Data
  let mediaType: String
  public static let adapter = "living-atlas/chatgpt-mapping/1"
}

func chatJSON<T: Encodable>(_ value: T) throws -> String {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try enc.encode(value), as: UTF8.self)
}
func chatDigest(_ fields: [String]) -> String {
  atlasHash(Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8))
}

/// A UUIDv8 name derived from a length-delimited namespace; message content digests remain full SHA-256.
func chatID(_ fields: [String]) -> String {
  var bytes = Array(chatDigest(fields).utf8.prefix(32))
  bytes[12] = Character("8").asciiValue!
  let variant = (Int(String(UnicodeScalar(bytes[16])), radix: 16)! & 3) | 8
  bytes[16] = Array(String(variant, radix: 16).utf8)[0]
  return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map {
    String(decoding: bytes[$0], as: UTF8.self)
  }.joined(separator: "-")
}

func chatLF(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

public enum ChatArchiveParser {
  public static func preview(file: URL, namespace: String) throws -> ChatImportPreview {
    let info = try file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
    guard info.isSymbolicLink != true else { throw ChatImportError("请选择导出文件或目录本身。") }
    if info.isDirectory == true {
      return try preview(
        bytes: ChatExportZIP.directorySnapshot(file),
        filename: file.lastPathComponent + "（目录快照）.zip", namespace: namespace)
    }
    let n = info.fileSize ?? 0
    guard n <= 1024 * 1024 * 1024 else { throw ChatImportError("文件超过本次 1 GiB 读取上限。") }
    return try preview(
      bytes: Data(contentsOf: file), filename: file.lastPathComponent, namespace: namespace,
      plain: file.pathExtension.lowercased() == "txt")
  }
  public static func pasted(_ text: String, namespace: String) throws -> ChatImportPreview {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ChatImportError("请先粘贴文本。")
    }
    return try preview(
      bytes: Data(text.utf8), filename: "粘贴文本.txt", namespace: namespace, plain: true)
  }
  public static func preview(bytes: Data, filename: String, namespace: String, plain: Bool = false)
    throws -> ChatImportPreview
  {
    let ns = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ns.isEmpty else { throw ChatImportError("请填写可区分导出来源的名称。") }
    guard bytes.count <= 1024 * 1024 * 1024 else { throw ChatImportError("文件超过本次 1 GiB 读取上限。") }
    let sha = atlasHash(bytes)
    let zip =
      !plain && (bytes.starts(with: [0x50, 0x4b]) || filename.lowercased().hasSuffix(".zip"))
    var diagnostics: [String] = []
    var output: [ChatParsedConversation] = []
    var ids = Set<String>()
    if plain {
      guard let body = String(data: bytes, encoding: .utf8),
        bytes.count <= ChatExportZIP.maxJSONBytes
      else {
        throw ChatImportError("粘贴文本超出读取范围，或编码无法识别。")
      }
      let loc = ChatRawLocation(member: nil, pointer: "")
      let part = ChatContentPart(
        kind: "text", text: body, attachment: nil, status: "parsed", index: 0)
      let m = ChatParsedMessage(
        externalID: nil, role: "unknown", roleRaw: nil, timestamp: nil, parent: nil,
        body: chatLF(body), parts: [part], location: loc, digest: sha)
      output.append(
        .init(
          id: chatID([ns, sha]), externalID: nil,
          title: String((body.split(separator: "\n").first ?? "").prefix(50)), location: loc,
          messages: [m]))
    } else {
      func parse(_ data: Data, member: String?, attachment: (String) -> (String, String)?) {
        let name = member ?? filename
        do {
          guard data.count <= ChatExportZIP.maxJSONBytes else {
            throw ChatImportError("单个 JSON 超过 512 MiB。")
          }
          let json = try JSONSerialization.jsonObject(with: data)
          let rows: [Any]
          let base: String
          let singleton: Bool
          if let arr = json as? [Any] {
            rows = arr
            base = ""
            singleton = false
          } else if let obj = json as? [String: Any], let arr = obj["conversations"] as? [Any] {
            rows = arr
            base = "/conversations"
            singleton = false
          } else if let obj = json as? [String: Any], obj["mapping"] != nil {
            rows = [obj]
            base = ""
            singleton = true
          } else {
            diagnostics.append("\(name)：未识别会话结构，原字段随原件保存。")
            return
          }
          for (i, value) in rows.enumerated() {
            let pointer = singleton ? "" : "\(base)/\(i)"
            guard let row = value as? [String: Any], let mapping = row["mapping"] as? [String: Any]
            else {
              diagnostics.append("\(name)\(pointer)：无法识别会话，原字段保留在原件。")
              continue
            }
            do {
              let c = try conversation(
                row, mapping: mapping, location: .init(member: member, pointer: pointer),
                namespace: ns, sha: sha, attachment: attachment, diagnostics: &diagnostics)
              guard ids.insert(c.id).inserted else {
                diagnostics.append("\(name)\(pointer)：包内会话标识重复，未覆盖先前会话。")
                continue
              }
              output.append(c)
            } catch { diagnostics.append("\(name)\(pointer)：\(error.localizedDescription)") }
          }
        } catch { diagnostics.append("\(name)：\(error.localizedDescription)") }
      }
      if zip {
        do {
          let archive = try ChatExportZIP(bytes)
          let members = Dictionary(
            uniqueKeysWithValues: archive.members.filter { !$0.directory }.map { ($0.name, $0) })
          var cached: [String: String] = [:]
          var attachmentErrors = [String]()
          for member in archive.members
          where !member.directory && member.name.lowercased().hasSuffix(".json") {
            do {
              parse(try archive.bytes(member), member: member.name) { reference in
                let folder = member.name.split(separator: "/").dropLast().joined(separator: "/")
                let relative = folder.isEmpty ? reference : folder + "/" + reference
                guard let item = members[reference] ?? members[relative] else { return nil }
                if let hash = cached[item.name] { return (item.name, hash) }
                do {
                  let hash = atlasHash(try archive.bytes(item))
                  cached[item.name] = hash
                  return (item.name, hash)
                } catch {
                  attachmentErrors.append(error.localizedDescription)
                  return nil
                }
              }
            } catch {
              diagnostics.append(error.localizedDescription)
            }
          }
          diagnostics += attachmentErrors
        } catch { diagnostics.append(error.localizedDescription) }
      } else {
        parse(bytes, member: nil) { _ in nil }
      }
      if output.isEmpty && diagnostics.isEmpty {
        diagnostics.append("\(filename)：未找到支持的会话记录，可仅保存原件。")
      }
    }
    return .init(
      filename: filename, namespace: ns, sha256: sha, provider: plain ? "plain_text" : "chatgpt",
      conversations: output, diagnostics: diagnostics, bytes: bytes,
      mediaType: plain ? "text/plain" : zip ? "application/zip" : "application/json")
  }

  private static func conversation(
    _ row: [String: Any], mapping: [String: Any], location: ChatRawLocation, namespace: String,
    sha: String, attachment: (String) -> (String, String)?, diagnostics: inout [String]
  ) throws -> ChatParsedConversation {
    let ext = nonempty(row["conversation_id"]) ?? nonempty(row["id"])
    let id =
      ext.map { chatID(["chatgpt", "conversation", namespace, $0]) }
      ?? chatID(["chatgpt", "anonymous", namespace, sha, location.member ?? "", location.pointer])
    let title = nonempty(row["title"]) ?? "未命名会话"
    let nodes = mapping.compactMapValues { $0 as? [String: Any] }
    for key in Set(mapping.keys).subtracting(nodes.keys).sorted() {
      diagnostics.append("无法识别消息记录：" + key)
    }
    let roots = nodes.keys.filter { k in
      (nonempty(nodes[k]?["parent"]).map { nodes[$0] == nil }) ?? true
    }.sorted()
    var seen = Set<String>()
    var ordered: [String] = []
    // Source children order is retained. Disconnected or malformed graphs also remain readable.
    for seed in roots + nodes.keys.sorted() where !seen.contains(seed) {
      var stack = [seed]
      while let key = stack.popLast(), let node = nodes[key] {
        guard seen.insert(key).inserted else { continue }
        ordered.append(key)
        stack += (node["children"] as? [String] ?? []).reversed().filter { nodes[$0] != nil }
      }
    }
    var messages: [ChatParsedMessage] = []
    var messageIDs = Set<String>()
    for key in ordered {
      guard let node = nodes[key], !(node["message"] is NSNull) else { continue }
      let esc = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(
        of: "/", with: "~1")
      let loc = ChatRawLocation(
        member: location.member, pointer: location.pointer + "/mapping/" + esc + "/message")
      guard let msg = node["message"] as? [String: Any] else {
        diagnostics.append("\(title) / \(key)：消息结构无法识别。")
        continue
      }
      let mid = nonempty(msg["id"])
      if let mid, !messageIDs.insert(mid).inserted {
        diagnostics.append("\(title) / \(key)：重复消息标识，原始两项保留在文件中。")
        continue
      }
      let rawRole = (msg["author"] as? [String: Any]).flatMap { nonempty($0["role"]) }
      let role =
        ["user", "assistant", "system", "developer", "tool"].contains(rawRole ?? "")
        ? rawRole! : "unknown"
      let content = msg["content"] as? [String: Any] ?? [:]
      let kind = nonempty(content["content_type"]) ?? "unknown"
      var values: [Any] =
        (content["parts"] as? [Any]) ?? (content["text"] as? String).map { [$0] } ?? [content]
      if let attached = (msg["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]] {
        values += attached.map { value -> [String: Any] in
          var value = value
          value["content_type"] = "attachment"
          return value
        }
      }
      let parts: [ChatContentPart] = values.enumerated().map { index, value in
        if let t = value as? String,
          ["text", "multimodal_text", "code", "input_text", "output_text", "unknown"].contains(
            kind), kind != "unknown" || content["content_type"] == nil
        {
          return .init(kind: "text", text: t, attachment: nil, status: "parsed", index: index)
        }
        let dict = value as? [String: Any] ?? [:]
        let type = nonempty(dict["content_type"]) ?? kind
        if let t = dict["text"] as? String,
          ["text", "input_text", "output_text", "code"].contains(type)
        {
          return .init(kind: "text", text: t, attachment: nil, status: "parsed", index: index)
        }
        let pointer =
          nonempty(dict["asset_pointer"]) ?? nonempty(dict["file_id"]) ?? nonempty(dict["id"])
          ?? nonempty(dict["name"])
        let resolved = pointer.flatMap(attachment) ?? nonempty(dict["name"]).flatMap(attachment)
        return .init(
          kind: type, text: nil, attachment: pointer, archiveMember: resolved?.0,
          attachmentSHA256: resolved?.1,
          status: resolved != nil ? "archived" : pointer == nil ? "unsupported" : "unavailable",
          index: index)
      }
      let parent = nonempty(node["parent"]).flatMap {
        nonempty((nodes[$0]?["message"] as? [String: Any])?["id"])
      }
      let fingerprint = try chatJSON(parts)
      let stamp = timestamp(msg["create_time"])
      messages.append(
        .init(
          externalID: mid, role: role, roleRaw: rawRole, timestamp: stamp, parent: parent,
          body: chatLF(parts.compactMap(\.text).joined(separator: "\n")), parts: parts,
          location: loc,
          digest: chatDigest([fingerprint])))
    }
    return .init(
      id: id, externalID: ext, title: title, sourceCreated: timestamp(row["create_time"]),
      sourceModified: timestamp(row["update_time"]), currentNode: nonempty(row["current_node"]),
      location: location, messages: messages)
  }
  private static func nonempty(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s
  }
  private static func timestamp(_ value: Any?) -> String? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, abs(number.doubleValue) < 253_402_300_799
    {
      return Date(timeIntervalSince1970: number.doubleValue).ISO8601Format(
        .iso8601(timeZone: .gmt, includingFractionalSeconds: true))
    }
    if let s = value as? String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if formatter.date(from: s) != nil || (try? Date(s, strategy: .iso8601)) != nil { return s }
    }
    return nil
  }
}
