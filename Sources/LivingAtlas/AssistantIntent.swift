import AtlasCore
import Foundation

struct AssistantIntent: Decodable, Equatable {
  enum Action: String, Decodable { case open, organize, move }
  let action: Action
  let object: String
  var relativeTo: String?
  var position: AtlasRelativePosition?

  static let instruction = """
    将用户的一句操作请求解析成一个 JSON 对象。action 只允许 open（打开）、organize（整理）、move（空间移动）。
    object 和 relativeTo 必须逐字取自请求，包括“这个节点”等指代。move 还需要 relativeTo 和 position（above/below/left/right）。
    open 和 organize 只返回 action 和 object 两个字段。例如“带我看看星图”返回 {"action":"open","object":"星图"}。不要推断被省略的材料名、对象 ID 或方向。否定、条件、多个步骤、阅读顺序或不支持的请求请返回 {}。不要执行操作。
    """

  static func local(_ phrase: String) -> Self? {
    var text = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。！？!?")))
    for prefix in ["请帮我", "麻烦帮我", "帮我", "请"] where text.hasPrefix(prefix) {
      text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      break
    }
    if let match = text.wholeMatch(of: #/(?:把|将)(.+?)(?:移动到|挪到|放到|移到|排在|放在)(.+?)(?:的)?(下面|下方|上面|上方|左边|左侧|右边|右侧)/#) {
      let directions: [String: AtlasRelativePosition] = ["下面":.below,"下方":.below,"上面":.above,"上方":.above,
        "左侧":.left,"左边":.left,"右侧":.right,"右边":.right]
      return Self(action: .move, object: String(match.1), relativeTo: String(match.2), position: directions[String(match.3)])
    }
    for (verb, action) in [("打开", Action.open), ("定位到", .open), ("找到", .open), ("整理", .organize), ("梳理", .organize)]
      where text.hasPrefix(verb) {
      var object = String(text.dropFirst(verb.count))
      if object.hasPrefix("一下") { object.removeFirst(2) }
      if !object.isEmpty { return Self(action: action, object: object) }
    }
    return nil
  }

  static func decoded(_ output: String, phrase: String) throws -> Self {
    var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("```json\n"), cleaned.hasSuffix("\n```") {
      cleaned = String(cleaned.dropFirst(8).dropLast(4))
    }
    guard let intent = try? JSONDecoder().decode(Self.self, from: Data(cleaned.utf8)),
      !intent.object.isEmpty, phrase.contains(intent.object),
      intent.action == .move ? (intent.position != nil && intent.relativeTo.map { !$0.isEmpty && phrase.contains($0) } == true)
        : (intent.position == nil && intent.relativeTo == nil)
    else { throw AtlasStoreError.invalid("还不能确定你想操作什么。可以说“打开《状态恢复笔记》”，或指明要移动的两个节点和方向。") }
    return intent
  }

  static func refersToCurrent(_ term: String) -> Bool {
    ["这个","这篇","它","当前","这个节点","这个问题","这篇笔记","这篇文章","这份文档","当前笔记","当前文章","当前节点","所选节点"].contains(term.trimmingCharacters(in: .whitespaces))
  }

  static func matches(_ name: String, in choices: [AtlasStore.OrganizationChoice], current: Set<String>) -> [AtlasStore.OrganizationChoice] {
    let term = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "《》「」“”\"")))
    guard !term.isEmpty else { return [] }
    if refersToCurrent(term) {
      return current.isEmpty ? choices : choices.filter { current.contains($0.id) }
    }
    if ["另一个","另一个节点","另外一个节点"].contains(term) { return choices }
    let exact = choices.filter { $0.title.localizedCaseInsensitiveCompare(term) == .orderedSame }
    return exact.isEmpty ? choices.filter { $0.title.localizedCaseInsensitiveContains(term) } : exact
  }
}
