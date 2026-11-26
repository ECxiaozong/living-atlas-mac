import AppKit
import AtlasCore
import SwiftUI

struct CodexCLISettings: View {
  let onSave: (ProviderProfile) throws -> Void
  let onClose: () -> Void
  @ViewState private var model: String?
  @ViewState private var status = "正在检测本机 Codex CLI…"
  @ViewState private var revision = 0
  @ViewState private var checking = true

  var body: some View {
    Text("使用这台 Mac 上已登录的官方 Codex CLI。推理在云端运行，使用该账号的 Codex 额度。")
      .font(.callout)
    Text(status).textSelection(.enabled)
    HStack {
      Button("选择 CLI 文件…") {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let file = panel.url {
          UserDefaults.standard.set(file.path, forKey: CodexCLI.pathPreference)
          refresh()
        }
      }.buttonStyle(PaperButton(compact: true))
      Button("重新检测") { refresh() }.buttonStyle(PaperButton(compact: true)).disabled(checking)
      Spacer()
      Button("返回", action: onClose).buttonStyle(PaperButton())
      Button("使用此连接") {
        guard let model else { return }
        do { try onSave(ProviderProfile(codexModel: model)) } catch {
          status = error.localizedDescription
        }
      }.buttonStyle(PaperButton(primary: true)).disabled(model == nil || checking)
    }
    .task(id: revision) {
      do {
        let detected = try await CodexCLI.inspect()
        try Task.checkCancellation()
        model = detected
        status = "已安装 · 已登录 · " + detected
      } catch {
        guard !Task.isCancelled else { return }
        model = nil
        status = error.localizedDescription
      }
      checking = false
    }
  }

  private func refresh() {
    model = nil
    checking = true
    status = "正在检测本机 Codex CLI…"
    revision += 1
  }
}
