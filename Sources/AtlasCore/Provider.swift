import Foundation
import Security

public enum ServiceError: LocalizedError {
  case address, model
  case http(Int)
  case protocolError, interrupted, emptyAnswer
  case streamError, streamQuota, streamAuth, streamRateLimit
  case keychain(OSStatus)
  case preparedProfile, outputBudget
  case truncated
  public var errorDescription: String? {
    switch self {
    case .address: return "请输入 HTTPS 服务地址，或使用本机回环地址。"
    case .preparedProfile: return "模型或账号已改变，请重新准备本次请求。"
    case .outputBudget: return "请在服务允许的范围内设置正数输出预算。"
    case .model: return "请输入服务中的模型名称。"
    case .http(let code): return "服务返回 HTTP \(code)。请检查模型、凭据和服务地址。"
    case .protocolError: return "服务返回的内容不符合 Chat Completions 流协议。"
    case .emptyAnswer: return "模型已结束生成，未返回可显示的回答。"
    case .streamError: return "模型服务在生成途中返回了错误，已有回答已保留。"
    case .streamQuota: return "模型服务报告余额或可用额度不足，请检查账号额度。"
    case .streamAuth: return "模型服务未接受本次身份验证，请检查模型配置。"
    case .streamRateLimit: return "模型服务暂时限制请求频率，请稍后重试。"
    case .interrupted: return "连接在生成结束前中断，已收到的回答仍可查看。"
    case .truncated: return "服务提前结束了回答，已保留收到的内容。"
    case .keychain(let status): return "钥匙串操作失败（\(status)）。"
    }
  }
}

public struct ProviderProfile: Codable, Equatable, Sendable {
  public let endpoint: URL
  /// Issued registration identifier only. OAuth credentials live in Keychain.
  public let subscriptionAccount: String?
  public let model: String
  static let legacyResponses = URL(string: "https://api.openai.com/v1/responses")!
  private static let cliEndpoint = URL(string: "codex-cli://local")!
  public var isCodexCLI: Bool { endpoint == Self.cliEndpoint }
  public var usesAPIKey: Bool { !isCodexCLI && subscriptionAccount == nil }
  public init(codexModel: String) throws {
    guard !codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.model }
    endpoint = Self.cliEndpoint
    subscriptionAccount = nil
    model = codexModel
  }
  public var serviceLabel: String {
    if isCodexCLI { return "本机 Codex CLI" }
    return subscriptionAccount == nil ? (endpoint.host ?? endpoint.absoluteString) : "ChatGPT 套餐"
  }
  public init(subscriptionAccount account: String, model: String) throws {
    guard !account.isEmpty, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ServiceError.model
    }
    endpoint = Self.legacyResponses
    subscriptionAccount = account
    self.model = model
  }
  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    if let account = try fields.decodeIfPresent(String.self, forKey: .subscriptionAccount) {
      try self.init(subscriptionAccount: account, model: fields.decode(String.self, forKey: .model))
      return
    }
    if try fields.decode(URL.self, forKey: .endpoint) == Self.cliEndpoint {
      try self.init(codexModel: fields.decode(String.self, forKey: .model))
      return
    }
    try self.init(
      address: fields.decode(String.self, forKey: .endpoint),
      model: fields.decode(String.self, forKey: .model))
  }
  public init(address: String, model: String) throws {
    guard
      let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = parts.host, parts.user == nil, parts.password == nil, parts.query == nil,
      parts.fragment == nil,
      parts.scheme == "https"
        || (parts.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)),
      let url = parts.url
    else { throw ServiceError.address }
    subscriptionAccount = nil
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !self.model.isEmpty else { throw ServiceError.model }
    endpoint =
      url.lastPathComponent == "completions" ? url : url.appendingPathComponent("chat/completions")
  }
  // Never follow redirects with model credentials or selected document text.
  final class DirectRequest: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  public func stream(
    question: String, quote: String?, previousAnswer: String? = nil, key: String?,
    onText: (String) async throws -> Void
  ) async throws {
    let prepared = try prepare(question: question, quote: quote, previousAnswer: previousAnswer)
    try await stream(prepared: prepared, key: key, onText: onText)
  }

  public func stream(
    prepared: PreparedProviderRequest, key: String?, onText: (String) async throws -> Void
  ) async throws {
    guard prepared.profile == self else { throw ServiceError.preparedProfile }
    try await send(body: prepared.body, key: key, onText: onText)
  }

  /// The receiver must be the profile originally recorded with the body.
  public func stream(frozenBody: Data, key: String?, cliInput: CodexCLI.Input? = nil, onUsage: (RunUsage) throws -> Void = { _ in }, onFinish: (String) throws -> Void = { _ in }, onText: (String) async throws -> Void)
    async throws
  {
    try checkFrozenBody(frozenBody)
    try await send(body: frozenBody, key: key, cliInput: cliInput, onUsage: onUsage, onFinish: onFinish, onText: onText)
  }

  public func stream(
    frozenBody: Data, recordedProfile: ProviderProfile, key: String?, cliInput: CodexCLI.Input? = nil, onUsage: (RunUsage) throws -> Void = { _ in }, onFinish: (String) throws -> Void = { _ in },
    onText: (String) async throws -> Void
  ) async throws {
    guard self == recordedProfile else { throw ServiceError.preparedProfile }
    try await stream(frozenBody: frozenBody, key: key, cliInput: cliInput, onUsage: onUsage, onFinish: onFinish, onText: onText)
  }

  private func send(body: Data, key: String?, cliInput: CodexCLI.Input? = nil, onUsage: (RunUsage) throws -> Void = { _ in }, onFinish: (String) throws -> Void = { _ in }, onText: (String) async throws -> Void) async throws {
    if isCodexCLI {
      try await CodexCLI.stream(body: body, model: model, input: cliInput, onUsage: onUsage, onFinish: onFinish, onText: onText)
      return
    }
    guard subscriptionAccount == nil else {
      throw AtlasStoreError.invalid("旧套餐连接已停用。请在模型设置中选择本机 Codex CLI 或 API 密钥。")
    }
    let session = URLSession(
      configuration: .ephemeral, delegate: DirectRequest(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let request = urlRequest(body: body, bearer: key)
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw ServiceError.protocolError }
    guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
    var received = false
    var endReason: String?
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" {
        if let endReason, endReason != "stop" { throw ServiceError.truncated }
        guard received else { throw ServiceError.emptyAnswer }
        return
      }
      guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
      else { throw ServiceError.protocolError }
      if let error = object["error"] as? [String: Any] {
        // Only classify known codes. Service messages can contain request material.
        let code = error["code"] as? String ?? error["type"] as? String
        switch code?.lowercased() {
        case "insufficient_balance", "insufficient_quota": throw ServiceError.streamQuota
        case "invalid_api_key", "authentication_error": throw ServiceError.streamAuth
        case "rate_limit_exceeded", "rate_limit_error": throw ServiceError.streamRateLimit
        default: throw ServiceError.streamError
        }
      }
      guard let choices = object["choices"] as? [[String: Any]] else { throw ServiceError.protocolError }
      if let usage = object["usage"] as? [String: Any] { try onUsage(RunUsage(chat: usage)) }
      if let item = choices.first {
        if let value = (item["delta"] as? [String: Any])?["content"] as? String, !value.isEmpty {
          received = true
          try await onText(value)
        }
        if let reason = item["finish_reason"] as? String { endReason = reason; try onFinish(reason) }
      }
    }
    if received && endReason == "stop" { return }
    throw ServiceError.interrupted
  }
}

public enum Credentials {
  private static func query(_ profile: ProviderProfile) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "LivingAtlas.ModelCredential",
      kSecAttrAccount as String: profile.endpoint.absoluteString,
    ]
  }
  public static func contains(_ profile: ProviderProfile) -> Bool {
    guard profile.usesAPIKey else { return false }
    return SecItemCopyMatching(query(profile) as CFDictionary, nil) == errSecSuccess
  }
  public static func read(_ profile: ProviderProfile) throws -> String? {
    guard profile.usesAPIKey else { return nil }
    var q = query(profile)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw ServiceError.keychain(status)
    }
    return String(decoding: data, as: UTF8.self)
  }
  public static func replace(_ key: String, for profile: ProviderProfile) throws {
    var q = query(profile)
    let value = [kSecValueData as String: Data(key.utf8)]
    var status = SecItemUpdate(q as CFDictionary, value as CFDictionary)
    if status == errSecItemNotFound {
      q.merge(value) { _, new in new }
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(q as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw ServiceError.keychain(status) }
  }
  public static func remove(_ profile: ProviderProfile) throws {
    let status = SecItemDelete(query(profile) as CFDictionary)
    guard status == errSecItemNotFound || status == errSecSuccess else {
      throw ServiceError.keychain(status)
    }
  }
}
