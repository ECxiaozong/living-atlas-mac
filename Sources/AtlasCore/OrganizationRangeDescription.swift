import Foundation

struct OrganizationTextMatches {
  var readable = Set<String>()
  var matches: [String: Set<String>] = [:]
}

/// The provider translates the user's words into predicates. The local catalog resolves all entrance IDs.
public enum OrganizationRangeDescription {
  public static let instruction = """
    将用户描述转成只读的画布入口筛选条件。只输出 JSON 对象，形如 {"include":[{"region":"地域原名","type":"markdown","version":1}],"exclude":[]}。
    每个条件内取交集，各 include 之间取并集，再去掉符合任一 exclude 的入口。body 是要求已显示版本的正文片段逐字包含的短语，也必须逐字取自用户描述。字段均可省略，但每个条件至少有一个字段。
    title 是标题包含的字词，region 是入口所属地域或其上级地域名，必须逐字取自用户描述，保留内外地域的区别。type 可为 pdf、markdown、turn（问答）、idea（灵感）、web_snapshot（网页）、content（内容节点）。version 是入口显示的正整数版本号。
    不得忽略否定、范围或时序限定。若需要按非字面语义、日期、未解状态或其他不可表示的条件判断，或指代不明，输出 {"unsupported":true}。不得生成 ID、动作或提案。
    """

  private struct Rule: Decodable {
    let title, region, type, body: String?
    let version: Int?

    func metadataMatches(_ item: AtlasStore.OrganizationChoice, path: String) -> Bool {
      if let title, !AtlasSearchText.fold(item.title).contains(AtlasSearchText.fold(title)) { return false }
      if let region, !OrganizationRangeDescription.includesRegion(region, path: path) { return false }
      if let type, type != item.materialKind && !(type == "content" && item.kind == "content") { return false }
      return version == nil || version == item.versionOrdinal
    }
  }

  private static func includesRegion(_ name: String, path: String) -> Bool {
    let value = AtlasSearchText.fold(name), path = AtlasSearchText.fold(path)
    return path == value || path.hasPrefix(value + " › ") || path.components(separatedBy: " › ").contains(value)
  }

  /// An exact title or region name works without a provider, including ancestors of folded regions.
  public static func literal(_ text: String, choices: [AtlasStore.OrganizationChoice], paths: [String: String]) -> Set<String>? {
    let name = AtlasSearchText.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !name.isEmpty else { return nil }
    let matched = choices.filter {
      AtlasSearchText.fold($0.title) == name || includesRegion(name, path: $0.regionID.flatMap { paths[$0] } ?? "画布根层")
    }
    return matched.isEmpty ? nil : Set(matched.map(\.id))
  }

  public static func resolve(_ response: String, description: String, choices: [AtlasStore.OrganizationChoice],
                             paths: [String: String], store: AtlasStore) async throws -> Set<String> {
    let invalid = organizationError("无法完整匹配这段描述。可指定地域、材料标题、类型或版本，再试一次。")
    var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
    if json.hasPrefix("```"), json.hasSuffix("```"), let start = json.firstIndex(of: "\n") {
      json = String(json[json.index(after: start)...].dropLast(3))
    }
    let data = Data(json.utf8)
    guard data.count <= 16_384, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(root.keys) == ["include", "exclude"] else { throw invalid }
    let original = AtlasSearchText.fold(description)
    func rules(_ key: String) throws -> [Rule] {
      guard let list = root[key] as? [[String: Any]], list.count <= 16 else { throw invalid }
      return try list.map { object in
        guard !object.isEmpty, Set(object.keys).isSubset(of: ["title","region","type","version","body"]),
              object.values.allSatisfy({ !($0 is NSNull) }),
              let rule = try? JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: object))
        else { throw invalid }
        if let body = rule.body, body.count > 120 { throw invalid }
        for term in [rule.title, rule.region, rule.body].compactMap({ $0 }) {
          guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, term.utf8.count <= 512,
                original.contains(AtlasSearchText.fold(term)) else { throw invalid }
        }
        if let type = rule.type, !["pdf","markdown","turn","idea","web_snapshot","content"].contains(type) { throw invalid }
        if let version = rule.version, version < 1 { throw invalid }
        return rule
      }
    }
    let include = try rules("include"), exclude = try rules("exclude")
    guard !include.isEmpty else { throw invalid }
    func path(_ item: AtlasStore.OrganizationChoice) -> String { item.regionID.flatMap { paths[$0] } ?? "画布根层" }
    let bodyRules = (include + exclude).filter { $0.body != nil }
    var texts = OrganizationTextMatches()
    if !bodyRules.isEmpty {
      let versions = choices.compactMap { item in
        bodyRules.contains { $0.metadataMatches(item, path: path(item)) } ? item.versionID : nil
      }
      texts = try AtlasSearchIndex(store: store).organizationTextMatches(
        terms: Set(bodyRules.compactMap(\.body)), versions: Set(versions))
    }
    return Set(choices.compactMap { item in
      func matches(_ rule: Rule) -> Bool? {
        guard rule.metadataMatches(item, path: path(item)) else { return false }
        guard let body = rule.body else { return true }
        guard let version = item.versionID, texts.readable.contains(version) else { return nil }
        return texts.matches[body]?.contains(version) == true
      }
      guard include.contains(where: { matches($0) == true }),
            exclude.allSatisfy({ matches($0) == false }) else { return nil }
      return item.id
    })
  }
}
