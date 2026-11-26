import AtlasIPC
import Foundation
import Security

public struct AtlasAgentGrant: Codable, Equatable, Sendable {
  /// nil denotes explicit permission over the entire current Atlas. Empty means no objects.
  public var objects: Set<String>? = []
  public var create = false, propose = false, apply = false, rollback = false,
    removeEntrance = false, history = false
  public init() {}
}

private struct DeviceGrant: Codable {
  let workspace, path, digest: String
  let permissions: AtlasAgentGrant
  let generation: String?
}

public final class AtlasAgentService: @unchecked Sendable {
  let worker = DispatchQueue(label: "LivingAtlas.AgentCommands", qos: .userInitiated)
  private let paths: AgentPaths
  private let preferences: UserDefaults
  private let preference = "atlas.agent.currentGrant.v1"
  private var server: AgentSocketServer?
  private var current: DeviceGrant?
  private var store: AtlasStore?
  var grantID: String? { current?.generation }
  var pages: [String: AgentPage] = [:]
  public init(paths: AgentPaths? = nil, preferences: UserDefaults = .standard) {
    self.paths =
      paths ?? ProcessInfo.processInfo.environment["LIVING_ATLAS_IPC_DIR"].map {
        AgentPaths(directory: URL(fileURLWithPath: $0))
      } ?? AgentPaths()
    self.preferences = preferences
  }
  public func attach(store next: AtlasStore?) {
    worker.sync {
      if store === next { return }
      release()
      store = next
      guard let next, let data = preferences.data(forKey: preference),
        let grant = try? JSONDecoder().decode(DeviceGrant.self, from: data),
        grant.workspace == next.workspaceID, grant.path == next.directory.standardizedFileURL.path,
        let cred = try? paths.readCredential(), cred.workspace == grant.workspace,
        atlasHash(Data(cred.token.utf8)) == grant.digest
      else { return }
      do {
        try listen()
        current = grant
      } catch { release() }
    }
  }
  private func release() {
    current = nil
    pages.removeAll()
    server?.stop()
    server = nil
  }
  private func listen() throws {
    guard server == nil else { return }
    let listener = AgentSocketServer(paths: paths) { [weak self] req in
      guard let self else { return AgentReply(req.requestID, error: .absent) }
      return self.worker.sync { self.handle(req) }
    }
    try listener.start()
    server = listener
  }
  public func permissions(for store: AtlasStore) -> AtlasAgentGrant? {
    worker.sync {
      guard self.store === store else { return nil }
      return current?.permissions
    }
  }
  public func authorize(_ grant: AtlasAgentGrant, for atlas: AtlasStore) throws {
    try worker.sync {
      guard store === atlas, FileManager.default.fileExists(atPath: atlas.directory.path) else {
        throw AgentFault.denied
      }
      // Opening the same graph routine seeds older projects' missing entrances once.
      if grant.propose || grant.apply || grant.rollback { _ = try atlas.atlasMap() }
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw AgentFault("IPC_UNAVAILABLE", "不能生成设备授权。")
      }
      let token = Data(bytes).base64EncodedString()
      let record = DeviceGrant(
        workspace: atlas.workspaceID, path: atlas.directory.standardizedFileURL.path,
        digest: atlasHash(Data(token.utf8)), permissions: grant, generation: UUID().uuidString)
      let data = try JSONEncoder().encode(record)
      try listen()
      do { try paths.publish(.init(workspace: atlas.workspaceID, token: token)) } catch {
        release()
        preferences.removeObject(forKey: preference)
        throw error
      }
      pages.removeAll()
      current = record
      preferences.set(data, forKey: preference)
    }
  }
  public func revoke() {
    worker.sync {
      if current != nil { try? paths.removeCredential() }
      release()
      preferences.removeObject(forKey: preference)
    }
  }
  private func handle(_ req: AgentRequest) -> AgentReply {
    do {
      guard req.protocolVersion == 1 else {
        throw AgentFault("PROTOCOL_UNSUPPORTED", "本机接口支持版本 1。")
      }
      guard let store, let current, req.workspace == store.workspaceID,
        current.workspace == store.workspaceID,
        FileManager.default.fileExists(atPath: store.directory.path),
        atlasHash(Data(req.capability.utf8)) == current.digest
      else { throw AgentFault.denied }
      guard !req.requestID.isEmpty, req.requestID.utf8.count <= 128 else {
        throw AgentFault.invalid
      }
      return AgentReply(
        req.requestID, result: try dispatch(req, store: store, grant: current.permissions))
    } catch let error as AgentFault { return AgentReply(req.requestID, error: error) } catch {
      return AgentReply(
        req.requestID, error: AgentFault("COMMAND_FAILED", "操作未完成，请在应用中查看版本、批次或材料状态。"))
    }
  }
}
