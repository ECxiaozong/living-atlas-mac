import Darwin
import Foundation

public struct AgentPaths: Sendable {
  public let directory: URL
  public var socket: URL { directory.appendingPathComponent("atlas.sock") }
  public var credential: URL { directory.appendingPathComponent("client.json") }
  public init(
    directory: URL = URL(
      fileURLWithPath: "/private/tmp/living-atlas-" + String(geteuid()), isDirectory: true)
  ) { self.directory = directory }
  func checkedDirectory(create: Bool) throws {
    if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
      throw AgentFault("IPC_UNAVAILABLE", "无法建立用户私有接口目录。")
    }
    var s = stat()
    guard lstat(directory.path, &s) == 0 else { throw AgentFault.absent }
    guard s.st_uid == geteuid(), s.st_mode & S_IFMT == S_IFDIR, s.st_mode & 0o777 == 0o700 else {
      throw AgentFault.denied
    }
  }
  func checkedSocket() throws -> ino_t {
    var s = stat()
    guard lstat(socket.path, &s) == 0 else { throw AgentFault.absent }
    guard s.st_uid == geteuid(), s.st_mode & S_IFMT == S_IFSOCK, s.st_mode & 0o777 == 0o600 else {
      throw AgentFault.denied
    }
    return s.st_ino
  }
  public func readCredential() throws -> AgentCredential {
    try checkedDirectory(create: false)
    let fd = open(credential.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw AgentFault.denied }
    defer { close(fd) }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & S_IFMT == S_IFREG,
      s.st_mode & 0o777 == 0o600, s.st_size > 0, s.st_size <= 4096
    else { throw AgentFault.denied }
    return try JSONDecoder().decode(
      AgentCredential.self, from: try SocketIO.read(fd, count: Int(s.st_size)))
  }
  public func publish(_ record: AgentCredential) throws {
    try checkedDirectory(create: true)
    let tmp = directory.appendingPathComponent(UUID().uuidString)
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw AgentFault("IPC_UNAVAILABLE", "无法保存本机客户端授权。") }
    defer {
      close(fd)
      unlink(tmp.path)
    }
    try SocketIO.write(fd, data: JSONEncoder().encode(record))
    guard fsync(fd) == 0, rename(tmp.path, credential.path) == 0 else {
      throw AgentFault("IPC_UNAVAILABLE", "无法登记客户端授权。")
    }
  }
  public func removeCredential() throws {
    try checkedDirectory(create: false)
    if unlink(credential.path) != 0 && errno != ENOENT {
      throw AgentFault("IPC_UNAVAILABLE", "无法清理客户端授权。")
    }
  }
}

enum SocketIO {
  static let maximum = 1_048_576
  static func make() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentFault.absent }
    configure(fd)
    return fd
  }
  static func configure(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var one: Int32 = 1
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
  }
  static func address<T>(_ path: String, _ call: (UnsafePointer<sockaddr>, socklen_t) -> T) throws
    -> T
  {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw AgentFault("IPC_PATH_TOO_LONG", "本机接口路径过长。")
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        call($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }
  static func sameUser(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
  }
  static func read(_ fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { ptr in
      guard let base = ptr.baseAddress else { return }
      var cursor = 0
      while cursor < count {
        let n = Darwin.read(fd, base.advanced(by: cursor), count - cursor)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw AgentFault("IPC_CLOSED", "本机连接已关闭。") }
        cursor += n
      }
    }
    return data
  }
  static func write(_ fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { ptr in
      guard let base = ptr.baseAddress else { return }
      var cursor = 0
      while cursor < data.count {
        let n = Darwin.write(fd, base.advanced(by: cursor), data.count - cursor)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw AgentFault("IPC_CLOSED", "本机连接已关闭。") }
        cursor += n
      }
    }
  }
  static func frame(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= maximum else {
      throw AgentFault("FRAME_SIZE", "单帧上限为 1 MiB。")
    }
    var n = UInt32(data.count).bigEndian
    return withUnsafeBytes(of: &n) { Data($0) } + data
  }
  static func next(_ fd: Int32) throws -> Data {
    let size = try read(fd, count: 4).reduce(0) { ($0 << 8) | Int($1) }
    guard size > 0, size <= maximum else { throw AgentFault("FRAME_SIZE", "单帧上限为 1 MiB。") }
    return try read(fd, count: size)
  }
}

public final class AgentSocketServer: @unchecked Sendable {
  public typealias Handler = @Sendable (AgentRequest) -> AgentReply
  private let paths: AgentPaths, handler: Handler,
    accepting = DispatchQueue(label: "LivingAtlas.IPC.accept")
  private let lock = NSLock()
  private var active = Set<Int32>(), source: DispatchSourceRead?
  private var inode: ino_t = 0
  public init(paths: AgentPaths = AgentPaths(), handler: @escaping Handler) {
    self.paths = paths
    self.handler = handler
  }
  public func start() throws {
    try paths.checkedDirectory(create: true)
    var s = stat()
    if lstat(paths.socket.path, &s) == 0 {
      _ = try paths.checkedSocket()
      let probe = try SocketIO.make()
      defer { close(probe) }
      let result = try SocketIO.address(paths.socket.path) { connect(probe, $0, $1) }
      guard result != 0 && errno == ECONNREFUSED else {
        throw AgentFault("IPC_IN_USE", "另一个应用实例正在使用本机接口。")
      }
      guard unlink(paths.socket.path) == 0 else { throw AgentFault.denied }
    }
    let fd = try SocketIO.make()
    var bound = false
    do {
      guard try SocketIO.address(paths.socket.path, { bind(fd, $0, $1) }) == 0 else {
        throw AgentFault("IPC_IN_USE", "无法绑定本机接口。")
      }
      bound = true
      guard chmod(paths.socket.path, 0o600) == 0, listen(fd, 8) == 0 else {
        throw AgentFault.denied
      }
      inode = try paths.checkedSocket()
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: accepting)
      listener.setEventHandler { [weak self] in self?.acceptClients(fd) }
      listener.setCancelHandler { close(fd) }
      lock.withLock { source = listener }
      listener.resume()
    } catch {
      close(fd)
      if bound { unlink(paths.socket.path) }
      throw error
    }
  }
  private func acceptClients(_ fd: Int32) {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 {
        if errno == EINTR { continue }
        return
      }
      let permitted = lock.withLock { () -> Bool in
        guard source != nil, active.count < 8, SocketIO.sameUser(c) else { return false }
        active.insert(c)
        return true
      }
      guard permitted else {
        close(c)
        continue
      }
      SocketIO.configure(c)
      _ = fcntl(c, F_SETFL, 0)
      DispatchQueue.global(qos: .utility).async { [self] in
        defer {
          lock.withLock {
            _ = active.remove(c)
            close(c)
          }
        }
        do {
          while true {
            let data = try SocketIO.next(c)
            let reply: AgentReply
            if let request = try? JSONDecoder().decode(AgentRequest.self, from: data) {
              reply = handler(request)
            } else {
              reply = AgentReply(nil, error: .invalid)
            }
            let encoded = try JSONEncoder().encode(reply)
            let dataToSend =
              encoded.count <= SocketIO.maximum
              ? encoded
              : try JSONEncoder().encode(
                AgentReply(reply.requestID, error: AgentFault("PAGE_TOO_LARGE", "请减小 limit 分页读取。")))
            try SocketIO.write(c, data: SocketIO.frame(dataToSend))
          }
        } catch {}
      }
    }
  }
  public func stop() {
    lock.withLock {
      source?.cancel()
      source = nil
      for fd in active { shutdown(fd, SHUT_RDWR) }
      if inode != 0, (try? paths.checkedSocket()) == inode { unlink(paths.socket.path) }
      inode = 0
    }
  }
  deinit { stop() }
}

public enum AgentClient {
  public static func request(
    method: String, workspace: String?, params: [String: AgentValue], id: String,
    paths: AgentPaths = AgentPaths()
  ) throws -> AgentReply {
    try paths.checkedDirectory(create: false)
    _ = try paths.checkedSocket()
    let fd = try SocketIO.make()
    defer { close(fd) }
    guard try SocketIO.address(paths.socket.path, { connect(fd, $0, $1) }) == 0 else {
      throw AgentFault.absent
    }
    guard SocketIO.sameUser(fd) else { throw AgentFault.denied }
    let credentials = try paths.readCredential()
    let req = AgentRequest(
      method: method, workspace: workspace ?? credentials.workspace, params: params,
      capability: credentials.token, requestID: id)
    try SocketIO.write(fd, data: SocketIO.frame(JSONEncoder().encode(req)))
    let reply = try JSONDecoder().decode(AgentReply.self, from: SocketIO.next(fd))
    guard reply.protocolVersion == 1, reply.requestID == id else {
      throw AgentFault("PROTOCOL_UNSUPPORTED", "接口版本或请求编号不匹配。")
    }
    return reply
  }
}
