import AtlasIPC
import Darwin
import Foundation

do {
  var args = Array(CommandLine.arguments.dropFirst())
  if args == ["--help"] || args == ["help"] {
    let info: [String: [String]] = [
      "commands": [
        "workspace list", "read", "search", "content create", "proposal submit", "batch diff",
        "batch apply", "batch rollback",
      ],
      "options": [
        "--workspace ID", "--request-id ID", "--id ID", "--version ID", "--query WORDS",
        "--limit N", "--cursor TOKEN", "--offset N", "--scope JSON_ARRAY", "--json -",
      ],
    ]
    FileHandle.standardOutput.write(try JSONEncoder().encode(info) + Data("\n".utf8))
    exit(0)
  }
  guard !args.isEmpty else {
    throw AgentFault(
      "USAGE",
      "atlas workspace list | read | search | content create | proposal submit | batch diff/apply/rollback。参数支持 --workspace、--request-id、--json（传 - 从标准输入读取）。"
    )
  }
  var method = args.removeFirst()
  if ["workspace", "content", "proposal", "batch"].contains(method) {
    guard !args.isEmpty else { throw AgentFault.invalid }
    method += "." + args.removeFirst()
  }
  let aliases = [
    "propose": "proposal.submit", "diff": "batch.diff", "apply": "batch.apply",
    "rollback": "batch.rollback",
  ]
  method = aliases[method] ?? method
  var workspace: String?
  var id = UUID().uuidString
  var params: [String: AgentValue] = [:]
  while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { throw AgentFault.invalid }
    let value = args.removeFirst()
    switch flag {
    case "--workspace": workspace = value
    case "--request-id": id = value
    case "--json":
      let data: Data
      if value == "-" {
        var input = Data()
        while let part = try FileHandle.standardInput.read(upToCount: 32768), !part.isEmpty {
          input += part
          guard input.count <= 1_048_576 else { throw AgentFault.invalid }
        }
        data = input
      } else {
        data = Data(value.utf8)
      }
      params = try JSONDecoder().decode([String: AgentValue].self, from: data)
    case "--scope":
      params["scope"] = try .encoded(JSONDecoder().decode([String].self, from: Data(value.utf8)))
    case "--limit", "--offset":
      guard let n = Int(value) else { throw AgentFault.invalid }
      params[String(flag.dropFirst(2))] = .number(Double(n))
    case "--id", "--version", "--query", "--cursor", "--body", "--kind":
      params[String(flag.dropFirst(2))] = .string(value)
    default: throw AgentFault.invalid
    }
  }
  let paths =
    ProcessInfo.processInfo.environment["LIVING_ATLAS_IPC_DIR"].map {
      AgentPaths(directory: URL(fileURLWithPath: $0))
    } ?? AgentPaths()
  let result = try AgentClient.request(
    method: method, workspace: workspace, params: params, id: id, paths: paths)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
  if result.error != nil { exit(2) }
} catch {
  let fault = error as? AgentFault ?? .invalid
  let data = try JSONEncoder().encode(AgentReply(nil, error: fault))
  FileHandle.standardOutput.write(data + Data("\n".utf8))
  FileHandle.standardError.write(Data((fault.localizedDescription + "\n").utf8))
  exit(2)
}
