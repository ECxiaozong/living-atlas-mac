import AtlasCore
import SwiftUI

struct ModelSettings: View {
  @EnvironmentObject var s: Session
  @Environment(\.dismiss) var dismiss
  @ViewState private var useCLI = false
  @AppStorage("lastAPIProfile") private var lastAPIProfile = Data()
  @ViewState private var address = ""
  @ViewState private var model = ""
  @ViewState private var secret = ""
  @ViewState private var message = ""
  @ViewState private var hasKey = false
  @ViewState private var testing = false
  @ViewState private var testTask: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("模型连接").font(.system(size: 21, weight: .medium, design: .serif))
      if let active = s.profile {
        Text("当前服务 · " + active.serviceLabel + " · " + active.model)
          .font(.callout).foregroundStyle(AtlasPalette.umber)
      }
      PaperRule()
      Picker("连接方式", selection: $useCLI) {
        Text("DeepSeek / API 密钥").tag(false)
        Text("使用本机 Codex CLI").tag(true)
      }.pickerStyle(.segmented)
      Text("生成时发送本次问题和引用的材料。").font(.callout).foregroundStyle(AtlasPalette.umber)
      if useCLI {
        CodexCLISettings(
          onSave: { profile in
            if let current = s.profile, current.usesAPIKey {
              lastAPIProfile = try JSONEncoder().encode(current)
            }
            try s.saveProfile(profile)
            dismiss()
          }, onClose: { dismiss() })
      } else {
        Text("服务地址").font(.caption).foregroundStyle(AtlasPalette.umber)
        TextField("https://…/v1", text: $address).textFieldStyle(.roundedBorder)
        Text("模型").font(.caption).foregroundStyle(AtlasPalette.umber)
        TextField("模型标识", text: $model).textFieldStyle(.roundedBorder)
        Text(hasKey ? "已保存到钥匙串 · 输入新密钥可替换" : "API 密钥 · 仅存入此 Mac 的钥匙串")
          .font(.caption).foregroundStyle(AtlasPalette.umber)
        SecureField("凭据", text: $secret).textFieldStyle(.roundedBorder)
        HStack {
          if hasKey {
            Button("移除已存凭据") {
              do {
                let p = try parsed()
                try Credentials.remove(p)
                hasKey = false
                secret = ""
                message = "已从钥匙串移除"
              } catch { message = error.localizedDescription }
            }.buttonStyle(PaperButton(compact: true))
          }
          Spacer()
          if testing { ProgressView().controlSize(.small) }
          Button(testing ? "连接中…" : "测试连接") { test() }
            .buttonStyle(PaperButton(compact: true))
            .disabled(testing)
        }
        if !message.isEmpty {
          Text(message).font(.callout).foregroundStyle(AtlasPalette.blueInk).textSelection(.enabled)
        }
        PaperRule()
        HStack {
          Spacer()
          Button("返回") { dismiss() }.buttonStyle(PaperButton())
          Button("保存配置并返回") { save() }.buttonStyle(PaperButton(primary: true))
        }
      }
    }.padding(24).frame(width: 480).background(AtlasPalette.paper)
      .onAppear {
        let currentAPI =
          s.profile.flatMap { $0.usesAPIKey ? $0 : nil }
          ?? (try? JSONDecoder().decode(ProviderProfile.self, from: lastAPIProfile))
        useCLI = s.profile?.isCodexCLI == true
        address = currentAPI?.endpoint.absoluteString ?? "https://api.deepseek.com"
        model = currentAPI?.model ?? "deepseek-flash"
        inspect()
      }
      .onChange(of: useCLI) { _, _ in testTask?.cancel() }
      .onChange(of: address) { _, _ in
        testTask?.cancel()
        message = ""
        secret = ""
        inspect()
      }
      .onChange(of: model) { _, _ in
        testTask?.cancel()
        message = ""
        inspect()
      }
      .onDisappear {
        testTask?.cancel()
        secret = ""
      }
  }
  func parsed() throws -> ProviderProfile { try ProviderProfile(address: address, model: model) }
  func inspect() { hasKey = (try? parsed()).map(Credentials.contains) ?? false }
  func test() {
    testTask?.cancel()
    do {
      let p = try parsed()
      let key = try secret.isEmpty ? Credentials.read(p) : secret
      testing = true
      message = "正在用一条合成问题测试连接…"
      testTask = Task { @MainActor in
        defer { testing = false }
        do {
          try await p.stream(question: "仅回答一个字：好", quote: nil, key: key) { _ in }
          if !Task.isCancelled { message = "连接成功，已收到模型输出。" }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
      }
    } catch { message = error.localizedDescription }
  }
  func save() {
    do {
      let p = try parsed()
      if !secret.isEmpty { try Credentials.replace(secret, for: p) }
      lastAPIProfile = try JSONEncoder().encode(p)
      try s.saveProfile(p)
      dismiss()
    } catch { message = error.localizedDescription }
  }
}
