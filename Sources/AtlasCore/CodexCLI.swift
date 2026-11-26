import Darwin
import Foundation

/// A single local stdio connection per generation. Codex owns authentication.
public enum CodexCLI {
  public struct Input: Sendable {
    let instructions: String
    let text: String
  }
  /// These two values are the static model input on the app-server boundary.
  static func envelope(_ body: Data) throws -> Input {
    guard let packet = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let messages = packet["messages"] as? [[String: String]], messages.first?["role"] == "system",
      let instructions = messages.first?["content"]
    else { throw ServiceError.preparedProfile }
    let data = try JSONSerialization.data(withJSONObject: ["messages": Array(messages.dropFirst())],
      options: [.sortedKeys, .withoutEscapingSlashes])
    return Input(instructions: instructions, text: String(decoding: data, as: UTF8.self))
  }
  private typealias Object = [String: Any]

  public static func executable() throws -> URL {
    let fm = FileManager.default
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
      .filter { $0.hasPrefix("/") }.map {
        URL(fileURLWithPath: $0).appendingPathComponent("codex").path
      }
    let candidates =
      paths + [
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
      ]
    guard
      let path = candidates.first(where: { path in
        var directory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
          && fm.isExecutableFile(atPath: path)
      })
    else { throw AtlasStoreError.invalid("未找到 Codex CLI。请安装官方 CLI，或在设置中选择可执行文件。") }
    return URL(fileURLWithPath: path)
  }

  public static let pathPreference = "codexCLI.executable"
  static func configuredExecutable() throws -> URL {
    if let path = UserDefaults.standard.string(forKey: pathPreference), !path.isEmpty {
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw AtlasStoreError.invalid("已选的 Codex CLI 不可执行，请重新选择。")
      }
      return URL(fileURLWithPath: path)
    }
    return try executable()
  }

  private final class Connection {
    let process = Process()
    let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var activeTurn: (thread: String, turn: String)?
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws {
      let url = try CodexCLI.configuredExecutable()
      let fm = FileManager.default
      try fm.createDirectory(at: directory, withIntermediateDirectories: false)
      process.executableURL = url
      process.currentDirectoryURL = directory
      // Keep local CLI credentials under its own management. Exclude API-key and provider overrides.
      let inherited = ProcessInfo.processInfo.environment
      var env = inherited.filter {
        ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "CODEX_HOME", "PATH"].contains($0.key)
      }
      env["PATH"] = url.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
      process.environment = env
      process.arguments = [
        "app-server", "--stdio", "-c", "forced_login_method=\"chatgpt\"",
        "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}", "-c", "project_doc_max_bytes=0",
        "--disable", "apps", "--disable", "plugins", "--disable", "hooks", "--disable", "memories",
        "--disable", "shell_tool", "--disable", "multi_agent",
      ]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      do { try process.run() } catch {
        try? fm.removeItem(at: directory)
        throw error
      }
    }
    func send(_ object: Object) throws {
      try Task.checkCancellation()
      try write(object)
    }
    private func write(_ object: Object) throws {
      var data = try JSONSerialization.data(withJSONObject: object)
      data.append(10)
      try lock.withLock { try input.fileHandleForWriting.write(contentsOf: data) }
    }
    func bind(thread: String, turn: String) {
      lock.withLock { activeTurn = (thread, turn) }
    }
    func interrupt() {
      if let active = lock.withLock({ activeTurn }) {
        try? write([
          "method": "turn/interrupt", "id": 6,
          "params": ["threadId": active.thread, "turnId": active.turn],
        ])
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.stop() }
      } else {
        stop()
      }
    }
    func stop() {
      lock.withLock { if process.isRunning { process.terminate() } }
    }
    func close() {
      lock.withLock { try? input.fileHandleForWriting.close() }
      stop()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  /// The model list and account type come from the same official CLI as the subsequent turn.
  public static func inspect() async throws -> String {
    try await run(body: nil, model: nil) { _ in }
  }

  static func stream(body: Data, model: String, input: Input?, onUsage: (RunUsage) throws -> Void, onFinish: (String) throws -> Void, onText: (String) async throws -> Void) async throws
  {
    _ = try await run(body: body, model: model, input: input, onUsage: onUsage, onFinish: onFinish, onText: onText)
  }

  private static func run(body: Data?, model: String?, input: Input? = nil, onUsage: (RunUsage) throws -> Void = { _ in }, onFinish: (String) throws -> Void = { _ in }, onText: (String) async throws -> Void)
    async throws -> String
  {
    let envelope = try input ?? body.map(Self.envelope)
    let connection = try Connection()
    // A missing/incompatible CLI must not leave the settings sheet checking indefinitely.
    let handshakeTimeout = DispatchWorkItem { connection.stop() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: handshakeTimeout)
    defer {
      handshakeTimeout.cancel()
      connection.close()
    }
    return try await withTaskCancellationHandler {
      func request(_ id: Int, _ method: String, _ params: Object) throws {
        try connection.send(["id": id, "method": method, "params": params])
      }
      try request(
        1, "initialize",
        [
          "clientInfo": ["name": "living_atlas", "title": "Living Atlas", "version": "1"],
          "capabilities": ["experimentalApi": true],
        ])
      var thread: String?
      var turnID: String?
      var received = false
      var commentary = Set<String>()
      var delivered = Set<String>()
      for try await line in connection.output.fileHandleForReading.bytes.lines {
        try Task.checkCancellation()
        guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? Object else {
          throw ServiceError.interrupted
        }
        if let id = event["id"] as? Int, event["method"] == nil {
          if let error = event["error"] as? Object {
            throw AtlasStoreError.invalid("Codex CLI：" + (error["message"] as? String ?? "请求失败"))
          }
          let result = event["result"] as? Object ?? [:]
          switch id {
          case 1:
            try connection.send(["method": "initialized"])
            try request(2, "account/read", ["refreshToken": false])
          case 2:
            guard (result["account"] as? Object)?["type"] as? String == "chatgpt" else {
              throw AtlasStoreError.invalid("请在终端运行 codex login，使用自己的 ChatGPT 账号登录，然后重新检测。")
            }
            if let model {
              try request(
                3, "thread/start",
                [
                  "model": model, "modelProvider": "openai", "allowProviderModelFallback": false,
                  "cwd": connection.directory.path, "approvalPolicy": "never",
                  "sandbox": "read-only",
                  "ephemeral": true, "environments": [], "selectedCapabilityRoots": [],
                  "baseInstructions": envelope?.instructions ?? PreparedProviderRequest.answerPolicy,
                ])
            } else {
              try request(5, "model/list", [:])
            }
          case 3:
            guard let id = (result["thread"] as? Object)?["id"] as? String, let envelope else {
              throw ServiceError.interrupted
            }
            guard result["model"] as? String == model,
              result["modelProvider"] as? String == "openai"
            else {
              throw ServiceError.preparedProfile
            }
            thread = id
            try request(
              4, "turn/start",
              [
                "threadId": id,
                "input": [["type": "text", "text": envelope.text]],
              ])
          case 4:
            guard let thread, let turn = (result["turn"] as? Object)?["id"] as? String else {
              throw ServiceError.interrupted
            }
            turnID = turn
            connection.bind(thread: thread, turn: turn)
            handshakeTimeout.cancel()
          case 5:
            guard let models = result["data"] as? [Object],
              let name = models.first(where: { $0["isDefault"] as? Bool == true })?["model"]
                as? String
            else { throw AtlasStoreError.invalid("Codex CLI 未返回默认模型，请检查 CLI 版本和账号状态。") }
            return name
          default: break
          }
          continue
        }
        // Never grant a tool, approval or credential request from a child process.
        if let id = event["id"], event["method"] != nil {
          try connection.send([
            "id": id, "error": ["code": -32601, "message": "Unavailable in the reader"],
          ])
          continue
        }
        guard let params = event["params"] as? Object, let thread,
          params["threadId"] as? String == thread
        else { continue }
        if let id = params["turnId"] as? String, id != turnID { continue }
        switch event["method"] as? String {
        case "thread/tokenUsage/updated":
          if let turnID, params["turnId"] as? String == turnID,
            let usage = (params["tokenUsage"] as? Object)?["last"] as? Object {
            try onUsage(RunUsage(cli: usage))
          }
        case "item/started", "item/completed":
          guard let item = params["item"] as? Object, item["type"] as? String == "agentMessage",
            let id = item["id"] as? String
          else { continue }
          if item["phase"] as? String == "commentary" { commentary.insert(id) }
          if event["method"] as? String == "item/completed", !commentary.contains(id),
            !delivered.contains(id), let text = item["text"] as? String, !text.isEmpty
          {
            try await onText(text)
            received = true
          }
        case "item/agentMessage/delta":
          if let id = params["itemId"] as? String, !commentary.contains(id),
            let delta = params["delta"] as? String, !delta.isEmpty
          {
            try await onText(delta)
            delivered.insert(id)
            received = true
          }
        case "turn/completed":
          let turn = params["turn"] as? Object
          guard let turnID, turn?["id"] as? String == turnID else { continue }
          if let status = turn?["status"] as? String { try onFinish(status) }
          guard turn?["status"] as? String == "completed", received else {
            let message = (turn?["error"] as? Object)?["message"] as? String
            throw AtlasStoreError.invalid(message ?? "Codex CLI 提前结束，已收到的文字已保留。")
          }
          return model ?? ""
        default: break
        }
      }
      try Task.checkCancellation()
      throw AtlasStoreError.invalid("本机 Codex CLI 连接中断。请在模型设置里重新检测，已有回答可重试。")
    } onCancel: {
      connection.interrupt()
    }
  }
}
