import Foundation

public enum AgentValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case list([AgentValue])
  case object([String: AgentValue])
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([AgentValue].self) {
      self = .list(v)
    } else {
      self = .object(try c.decode([String: AgentValue].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .list(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
  public var text: String? {
    if case .string(let s) = self { return s }
    return nil
  }
  public var integer: Int? {
    if case .number(let s) = self { return Int(exactly: s) }
    return nil
  }
  public var fields: [String: AgentValue]? {
    if case .object(let o) = self { return o }
    return nil
  }
  public static func encoded<T: Encodable>(_ value: T) throws -> Self {
    try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
  }
  public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

public struct AgentFault: Error, LocalizedError, Codable, Equatable, Sendable {
  public let code, message: String
  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
  public var errorDescription: String? { "\(code) · \(message)" }
  public static let denied = Self("CAPABILITY_DENIED", "当前客户端没有此工作区、对象或命令的权限。")
  public static let invalid = Self("INVALID_REQUEST", "请求缺少必要字段或参数无效。")
  public static let absent = Self("APP_NOT_RUNNING", "请打开 Living Atlas，并在应用中启用本机接口。")
}

public struct AgentRequest: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case requestID = "request_id"
    case method, capability, workspace, params
  }
  public let protocolVersion: Int
  public let requestID, method, capability: String
  public let workspace: String?
  public let params: [String: AgentValue]
  public init(
    method: String, workspace: String?, params: [String: AgentValue] = [:], capability: String,
    requestID: String = UUID().uuidString, protocolVersion: Int = 1
  ) {
    self.protocolVersion = protocolVersion
    self.requestID = requestID
    self.method = method
    self.workspace = workspace
    self.params = params
    self.capability = capability
  }
}
public struct AgentReply: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case requestID = "request_id"
    case result, error
  }
  public let protocolVersion: Int
  public let requestID: String?
  public let result: AgentValue?
  public let error: AgentFault?
  public init(_ request: String?, result: AgentValue) {
    protocolVersion = 1
    requestID = request
    self.result = result
    error = nil
  }
  public init(_ request: String?, error: AgentFault) {
    protocolVersion = 1
    requestID = request
    result = nil
    self.error = error
  }
}
public struct AgentCredential: Codable, Sendable {
  public let workspace, token: String
  public init(workspace: String, token: String) {
    self.workspace = workspace
    self.token = token
  }
}
