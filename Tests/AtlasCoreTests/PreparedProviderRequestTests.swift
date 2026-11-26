import Foundation
import Network
import Testing

@testable import AtlasCore

@Suite struct PreparedProviderRequestTests {
  @Test func codexRecordingKeepsSelectionAndModelWithoutAPICredentials() throws {
    let profile = try ProviderProfile(codexModel: "test-model")
    let restored = try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(profile))
    #expect(restored == profile && restored.isCodexCLI && !restored.usesAPIKey)
    #expect(try Credentials.read(restored) == nil)
    let prepared = try restored.prepare(question: "怎样恢复？", quote: "进程结束后，对象随之释放。")
    try restored.checkFrozenBody(prepared.body)
    let packet = try #require(JSONSerialization.jsonObject(with: prepared.body) as? [String: Any])
    let messages = try #require(packet["messages"] as? [[String: String]])
    #expect(messages.compactMap { $0["content"] } == [
      prepared.systemPrompt, "所选材料：\n进程结束后，对象随之释放。", "怎样恢复？"])
    #expect(prepared.sentOutputTokens == nil)
  }

  @Test func hashesMatchWireBodyAndExactMaterialOrder() throws {
    let profile = try ProviderProfile(address: "https://api.deepseek.com", model: "deepseek-flash")
    let question = "解释\n第二行 👩🏽‍💻"
    let materials: [ProviderMaterial] = [
      .quotation("原文 e\u{301}"), .history("旧回答"), .quotation("原文 e\u{301}"),
    ]
    let p = try profile.prepare(question: question, materials: materials, maxOutputTokens: 511)
    let obj = try #require(JSONSerialization.jsonObject(with: p.body) as? [String: Any])
    let messages = try #require(obj["messages"] as? [[String: String]])
    #expect(
      messages.compactMap { $0["content"] } == [
        p.systemPrompt, "所选材料：\n原文 e\u{301}", "旧回答", "所选材料：\n原文 e\u{301}", question,
      ])
    #expect(p.systemPromptHash == atlasHash(Data(p.systemPrompt.utf8)))
    #expect(p.requestedOutputTokens == 511 && p.outputLimitParameter == "max_tokens")
    #expect((obj["max_tokens"] as? Int) == p.sentOutputTokens)
    let req = profile.urlRequest(body: p.body, bearer: "fixture-secret")
    #expect(!String(decoding: p.body, as: UTF8.self).contains("fixture-secret"))
    #expect(atlasHash(try #require(req.httpBody)) == p.payloadHash)
    #expect(
      try profile.prepare(question: question, materials: materials, maxOutputTokens: 511).body
        == p.body)
    #expect(throws: ServiceError.self) {
      try profile.prepare(question: question, materials: materials, maxOutputTokens: 0)
    }
    #expect(throws: ServiceError.self) {
      try profile.prepare(question: question, materials: materials, maxOutputTokens: 393_217)
    }
  }

  @Test func unsupportedBudgetIsRecordedAndTargetMismatchRejected() async throws {
    let plan = try ProviderProfile(subscriptionAccount: "workspace-one", model: "catalog-slug")
    let other = try ProviderProfile(subscriptionAccount: "workspace-two", model: "catalog-slug")
    let thirdParty = try ProviderProfile(address: "https://example.invalid", model: "catalog-slug")
    for profile in [plan, thirdParty] {
      let request = try profile.prepare(question: "问", materials: [], maxOutputTokens: 2500)
      #expect(request.requestedOutputTokens == 2500)
      #expect(request.sentOutputTokens == nil && request.outputLimitParameter == nil)
      let obj = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
      #expect(obj["max_tokens"] == nil && obj["max_output_tokens"] == nil)
      try profile.checkFrozenBody(request.body)
      await #expect(throws: ServiceError.self) {
        try await other.stream(frozenBody: request.body, recordedProfile: profile, key: nil) { _ in
        }
      }
    }
    let body = try plan.prepare(question: "问", materials: []).body
    #expect(throws: ServiceError.self) { try thirdParty.checkFrozenBody(body) }
    let changed = try ProviderProfile(subscriptionAccount: "workspace-one", model: "another-slug")
    #expect(throws: ServiceError.self) { try changed.checkFrozenBody(body) }
  }

  @Test func persistedNoncanonicalBodyArrivesByteForByte() async throws {
    let queue = DispatchQueue(label: "LivingAtlas.Tests.CapturePreparedRequest")
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: params)
    let (ports, portSink) = AsyncThrowingStream<UInt16, Error>.makeStream()
    let (bodies, bodySink) = AsyncThrowingStream<Data, Error>.makeStream()
    defer {
      listener.cancel()
      portSink.finish()
      bodySink.finish()
    }
    let unavailable = AtlasStoreError.invalid("测试服务未能收齐请求")
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready: if let port = listener.port { portSink.yield(port.rawValue) }
      case .failed(let error):
        portSink.finish(throwing: error)
        bodySink.finish(throwing: error)
      default: break
      }
    }
    listener.newConnectionHandler = { connection in
      func receive(_ existing: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
          chunk, _, done, error in
          guard error == nil, let chunk else {
            bodySink.finish(throwing: unavailable)
            connection.cancel()
            return
          }
          let packet = existing + chunk
          if let separator = packet.range(of: Data("\r\n\r\n".utf8)) {
            let headers = String(decoding: packet[..<separator.lowerBound], as: UTF8.self)
              .lowercased().components(separatedBy: "\r\n")
            let length = headers.first { $0.hasPrefix("content-length:") }.flatMap {
              Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces))
            }
            let body = Data(packet[separator.upperBound...])
            if body.count == length {
              bodySink.yield(body)
              let frames = [
                #"{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11}}"#,
                #"{"choices":[],"usage":{"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":0},"extra":true}}"#,
                "[DONE]", "[DONE]"
              ]
              let sse = frames.map { "data: " + $0 + "\n\n" }.joined()
              let response =
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(sse.utf8.count)\r\nConnection: close\r\n\r\n"
                + sse
              connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
              return
            }
          }
          if done || packet.count > 32768 {
            bodySink.finish(throwing: unavailable)
            connection.cancel()
          } else {
            receive(packet)
          }
        }
      }
      connection.start(queue: queue)
      receive(Data())
    }
    listener.start(queue: queue)
    var portIterator = ports.makeAsyncIterator()
    let port = try #require(try await portIterator.next())
    let profile = try ProviderProfile(address: "http://127.0.0.1:\(port)", model: "fixture")
    // Stored formatting deliberately differs from the current encoder. Validation may not reconstruct the body.
    let bytes = Data(
      #"{ "messages" : [{"role":"system","content":"约束"},{"role":"user","content":"问"}], "stream": true, "model": "fixture" }"#
        .utf8)
    var answer = ""
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try AtlasStore(directory: dir)
    let run = try store.start(question: "问")
    var reasons = [String]()
    try await profile.stream(frozenBody: bytes, recordedProfile: profile, key: nil,
      onUsage: { try store.recordUsage($0, for: run.id) }, onFinish: { reasons.append($0) }) {
      answer += $0
    }
    let usage = try #require(try store.usage(for: run.id))
    #expect(usage.input == 11 && usage.output == 1 && usage.cachedInput == 0)
    #expect(usage.cacheWrite == nil && usage.cacheMiss == nil && usage.status == "complete")
    #expect(reasons == ["stop"])
    var bodyIterator = bodies.makeAsyncIterator()
    #expect(try await bodyIterator.next() == bytes)
    #expect(answer == "好")
  }
}
